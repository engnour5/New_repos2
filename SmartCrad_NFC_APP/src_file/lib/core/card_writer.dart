import 'dart:math';
import 'dart:typed_data';

import 'applet.dart';
import 'card_profile.dart';
import 'card_reader.dart';
import 'error_map.dart';
import 'errors.dart';
import 'hex.dart';
import 'log.dart';
import 'platform.dart';
import 'session.dart';

/// What to write: [data] into the card's file from [offset] on, within a file of [fileSize] bytes.
class CardWriteRequest {
  CardWriteRequest(this.offset, this.data, {this.source = '', this.fileSize = CardReadResult.defaultSize});

  final int offset;
  final Uint8List data;

  /// Where the bytes came from, for the log and the screen: typed, a file, a fill, an undo.
  final String source;

  /// The size of the card's file, so a write that would go past the end is refused. From the card profile.
  final int fileSize;

  int get length => data.length;
  int get last => offset + data.length - 1;
  String get range => '${h4(offset)}-${h4(last)}';
  String get end => h4(fileSize - 1);

  /// Why the card's file cannot take this, or null when it fits.
  String? get problem {
    if (data.isEmpty) return 'There is nothing to write.';
    if (offset < 0 || offset >= fileSize) return 'The offset must be between 0000 and $end.';
    if (offset + data.length > fileSize) {
      return '${data.length} bytes from ${h4(offset)} would go past $end, the end of the card\'s file: at most '
          '${fileSize - offset} fit there.';
    }
    return null;
  }
}

/// What "Write card" did. The bytes that were there before are kept, so the write can be undone.
class CardWriteResult {
  CardWriteResult({
    required this.request,
    required this.platform,
    required this.time,
    required this.seconds,
    required this.commands,
    required this.done,
    required this.bytesSent,
    required this.partsWritten,
    required this.partsSkipped,
    this.before,
    this.after,
    this.cardId,
    this.error,
    this.warnings = const [],
  });

  final CardWriteRequest request;
  final PhonePlatform platform;
  final DateTime time;
  final double seconds;
  final int commands;

  /// Bytes of the request dealt with, from its start: written, or skipped because the card already held them.
  final int done;

  /// Bytes that went to the card with UPDATE BINARY.
  final int bytesSent;
  final int partsWritten;
  final int partsSkipped;

  /// What the card held there before the write, read first. It is what Undo writes back.
  final Uint8List? before;

  /// What the card holds there after the write, read back. Null when the write did not get that far.
  final Uint8List? after;

  /// The applet's card ID (GET UID), so an undo can make sure it goes to the same card.
  final Uint8List? cardId;
  final String? error;
  final List<String> warnings;

  /// Where the bytes that were there before were saved; set by the app, which owns the files.
  String? backupPath;

  bool get complete => done == request.length;
  bool get changedCard => bytesSent > 0;

  /// Every byte read back is the byte that was meant to be there.
  bool get verified => after != null && Hex.same(after, request.data);
  bool get ok => error == null && complete && verified;

  int get mismatches {
    final a = after;
    if (a == null) return 0;
    var n = 0;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != request.data[i]) n++;
    }
    return n;
  }

  int? get firstMismatch {
    final a = after;
    if (a == null) return null;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != request.data[i]) return request.offset + i;
    }
    return null;
  }

  /// Bytes that are now different from before.
  int get bytesChanged {
    final b = before;
    if (b == null) return 0;
    var n = 0;
    for (var i = 0; i < done; i++) {
      if (b[i] != request.data[i]) n++;
    }
    return n;
  }

  /// The one-line result, for the screen and the log.
  String get message {
    if (error != null) {
      return 'EXCEPTION: $error${done > 0 && done < request.length ? ' $done of ${request.length} bytes were done before it stopped.' : ''}';
    }
    if (after == null) {
      return 'NOT PROVEN: ${request.length} bytes went to ${request.range}, but they could not be read back to check them.';
    }
    if (!verified) {
      return 'EXCEPTION: the card holds something else than what was written, in $mismatches '
          'byte${mismatches == 1 ? '' : 's'}; the first is at ${h4(firstMismatch!)}.';
    }
    final changed = bytesChanged;
    return 'OK: the ${request.length} bytes at ${request.range} are on the card, checked by reading them back'
        '${changed == 0 ? ' (it held them already, so nothing had to be written)' : ' ($changed changed)'}'
        '${warnings.isEmpty ? '.' : ', with ${warnings.length} warning${warnings.length == 1 ? '' : 's'}.'}';
  }
}

/// Writes bytes into EF 3040 the way a phone app would, and proves it by reading them back:
/// - tap; SELECT the applet by its AID (a failure is a warning, as in Read card: the default applet may still answer),
///   then SELECT EF 3040, which has to work, because without it the applet refuses every write (69 86);
/// - READ the range first. Those are the bytes Undo puts back, so nothing is written when they cannot be read;
/// - UPDATE BINARY in parts of [part] bytes, leaving out the parts that already hold the new bytes when [skipUnchanged];
/// - READ the range again and compare it with what was meant to be there.
/// When the iPhone session runs out or the card stops answering, the card is tapped again, as a person would (at most
/// three times). Past that the write stops and says how far it got.
class CardWriter {
  CardWriter(this.s, this.log, this.request,
      {this.onProgress, this.skipUnchanged = true, this.expectCardId, Uint8List? appletAid, CardProfile? profile})
      : appletAid = appletAid ?? AppletAid.byDefault,
        profile = profile ?? CardProfile.emg;

  /// The most bytes one UPDATE BINARY carries: a short APDU, inside the 261 bytes many Android phones allow.
  static const part = 240;

  /// iOS drops the tag connection about this long after an app connects, as developers report (Apple forum 118922).
  static const iosConnectionSeconds = 20;

  final PhoneSession s;
  final Logger log;
  final CardWriteRequest request;
  final void Function(int done)? onProgress;
  final bool skipUnchanged;

  /// For an undo: the card ID the write was made on. Another card is not written.
  final Uint8List? expectCardId;
  final Uint8List appletAid;

  /// How this card is talked to: which file to select, how to read and write.
  final CardProfile profile;

  final _warnings = <String>[];
  var _commands = 0;
  var _retaps = 0;
  var _longestTap = 0.0;
  Uint8List? _cardId;

  Future<CardWriteResult> run() async {
    final watch = Stopwatch()..start();
    Uint8List? before, after;
    var done = 0, sent = 0, written = 0, skipped = 0;

    CardWriteResult result({String? error}) {
      if (s.platform == PhonePlatform.iphone && _longestTap > iosConnectionSeconds) {
        _warnings.add('One tap took ${_longestTap.toStringAsFixed(1)} s with this reader. Developers report that iOS '
            'drops the connection about $iosConnectionSeconds s after an app connects, so on an iPhone a write this '
            'long may need to be split, or the card tapped again.');
      }
      return CardWriteResult(
        request: request,
        platform: s.platform,
        time: DateTime.now(),
        seconds: watch.elapsedMicroseconds / 1e6,
        commands: _commands,
        done: done,
        bytesSent: sent,
        partsWritten: written,
        partsSkipped: skipped,
        before: before,
        after: after,
        cardId: _cardId,
        error: error,
        warnings: List.of(_warnings),
      );
    }

    final problem = request.problem;
    if (problem != null) return result(error: '$problem Nothing was sent to the card.');

    log.section('Write card as an ${s.platform.app}: ${request.length} bytes at ${request.range}'
        '${request.source.isEmpty ? '' : ' (${request.source})'}');
    try {
      if (!await s.tap()) {
        return result(
            error: s.platform == PhonePlatform.iphone
                ? 'the iPhone did not find the card: no AID of the app list answered 90 00. Nothing was written.'
                : 'the Android phone did not find an ISO-DEP card. Nothing was written.');
      }
      final cannot = await _prepare();
      if (cannot != null) return result(error: '$cannot Nothing was written.');

      // 1. what is there now: what Undo puts back, and what "skip unchanged" compares with
      final (old, why) = await _readRange('Write card: read what is there now');
      if (old == null) return result(error: 'the bytes there now could not be read ($why), and Undo needs them. Nothing was written.');
      before = old;

      // 2. the new bytes, part by part
      for (var pos = request.offset; pos <= request.last; pos += part) {
        final n = min(part, request.last - pos + 1);
        final at = pos - request.offset;
        final bytes = Uint8List.sublistView(request.data, at, at + n);
        if (skipUnchanged && Hex.same(Uint8List.sublistView(old, at, at + n), bytes)) {
          skipped++;
        } else {
          final r = await _send(profile.writeCommand(pos, bytes), 'Write card: UPDATE ${h4(pos)}-${h4(pos + n - 1)}');
          if (r == null) return result(error: 'the card could not be reached again at ${h4(pos)}.');
          if (!(r.ok && r.response!.sw == 0x9000)) {
            return result(error: 'UPDATE BINARY of $n bytes at ${h4(pos)} answered ${_answer(r)}.');
          }
          written++;
          sent += n;
        }
        done += n;
        onProgress?.call(done);
      }

      // 3. the proof: read it all back
      final (back, backWhy) = await _readRange('Write card: read back');
      if (back == null) {
        _warnings.add('The bytes could not be read back ($backWhy), so the write is not proven.');
      }
      after = back;
    } on CardException catch (e) {
      return result(error: 'the card could not be reached: ${e.message}');
    }

    final res = result();
    log.info('Write card: ${res.message} ${res.bytesSent} bytes sent in ${res.partsWritten} UPDATE BINARY, '
        '${res.partsSkipped} part${res.partsSkipped == 1 ? '' : 's'} already right, ${res.seconds.toStringAsFixed(2)} s.');
    for (final w in res.warnings) {
      log.warn(w);
    }
    return res;
  }

  /// SELECT the applet, GET UID, SELECT EF 3040. Returns why the write cannot go on, or null.
  Future<String?> _prepare() async {
    var r = await _send(Hex.parse(AppletAid.select(appletAid)), 'Write card: SELECT applet');
    if (r == null) return 'The card could not be reached.';
    if (r.status == SendStatus.blocked) {
      _warnings.add('SELECT of the applet by its AID (${Hex.of(appletAid)}) was not sent: iOS blocks it, because this '
          "AID is not in the app's AID list. The write went on with the applet that answered at the tap "
          '(initialSelectedAID ${s.initialSelectedAid}).');
    } else if (!(r.ok && r.response!.sw == 0x9000)) {
      _warnings.add('SELECT of the applet by its AID (${Hex.of(appletAid)}) answered ${_answer(r)}. The write went on '
          'with the applet the card selects by itself (its default applet).');
    }
    if (profile.hasIdCommand) {
      r = await _send(Hex.parse(profile.idCommand), 'Write card: card ID');
      if (r != null && r.ok && r.response!.sw == 0x9000 && r.response!.data.isNotEmpty) _cardId = r.response!.data;
    }
    final expected = expectCardId;
    if (expected != null && !Hex.same(_cardId, expected)) {
      return 'This is not the card the write was made on: its card ID is '
          '${_cardId == null ? 'unknown (the ID command failed)' : Hex.of(_cardId)}, not ${Hex.of(expected)}.';
    }
    if (profile.hasSelectFile) {
      r = await _send(Hex.parse(profile.selectFile), 'Write card: SELECT file');
      if (r == null || !(r.ok && r.response!.sw == 0x9000)) {
        return 'SELECT file (${profile.selectFile}) answered ${r == null ? 'nothing' : _answer(r)}, so there is no file to write into.';
      }
    }
    return null;
  }

  /// READ BINARY over the whole range, 256 bytes at a time. Returns the bytes, or null and why not.
  Future<(Uint8List?, String)> _readRange(String label) async {
    final out = Uint8List(request.length);
    for (var pos = request.offset; pos <= request.last; pos += 256) {
      final n = min(256, request.last - pos + 1);
      final r = await _send(Hex.parse(profile.readCommand(pos, n)), '$label ${h4(pos)}');
      if (r == null) return (null, 'the card could not be reached again at ${h4(pos)}');
      if (!(r.ok && r.response!.sw == 0x9000 && r.response!.data.length == n)) {
        return (null, 'READ of $n bytes at ${h4(pos)} answered ${_answer(r)}');
      }
      out.setRange(pos - request.offset, pos - request.offset + n, r.response!.data);
    }
    return (out, '');
  }

  /// One command. When the iPhone session has run out or the card stopped answering, the card is tapped again and the
  /// command sent once more; writing the same bytes to the same place twice changes nothing. Null when the card cannot
  /// be reached again.
  Future<SendResult?> _send(Uint8List apdu, String label) async {
    try {
      _commands++;
      var r = await s.send(apdu, label);
      if (r.status == SendStatus.expired || r.status == SendStatus.noCard) {
        if (!await _retap('the ${s.platform.short} session ended')) return null;
        _commands++;
        r = await s.send(apdu, label);
      }
      _longestTap = max(_longestTap, s.elapsed);
      return r;
    } on CardException catch (e) {
      log.warn('Write card: ${e.message}');
      if (!await _retap('the card stopped answering')) return null;
      try {
        _commands++;
        final r = await s.send(apdu, label);
        _longestTap = max(_longestTap, s.elapsed);
        return r;
      } on CardException {
        s.end();
        return null;
      }
    }
  }

  /// A new tap, then SELECT applet and SELECT the file again. At most 3 times per write.
  Future<bool> _retap(String why) async {
    if (_retaps >= 3) return false;
    _retaps++;
    _warnings.add('${why[0].toUpperCase()}${why.substring(1)}; the card was tapped again ($_retaps).');
    log.warn('Write card: $why. Tapping again.');
    try {
      if (!await s.tap()) return false;
      _commands++;
      await s.send(Hex.parse(AppletAid.select(appletAid)), 'Write card: SELECT applet (again)');
      if (!profile.hasSelectFile) return true;
      _commands++;
      final r = await s.send(Hex.parse(profile.selectFile), 'Write card: SELECT file (again)');
      return r.ok && r.response!.sw == 0x9000;
    } on CardException catch (e) {
      log.warn('Write card: the card could not be found again: ${e.message}');
      s.end();
      return false;
    }
  }

  static String _answer(SendResult r) =>
      r.ok ? '${r.response!.swText} (${explainAnswer(r.sent ?? r.typed, r.response!.sw).short})' : r.short;
}
