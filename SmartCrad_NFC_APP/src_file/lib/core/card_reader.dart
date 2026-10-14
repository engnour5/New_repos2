import 'dart:typed_data';

import 'applet.dart';
import 'card_profile.dart';
import 'crc32.dart';
import 'error_map.dart';
import 'errors.dart';
import 'hex.dart';
import 'log.dart';
import 'platform.dart';
import 'session.dart';

/// One 256-byte block of the card: how much of it was read, and why the rest was not.
class BlockRead {
  BlockRead(this.index);

  final int index;
  int bytes = 0; // bytes read from the start of the block, 0..256
  String? problem; // why the block (or its end) could not be read

  int get start => index * 256;
  bool get complete => bytes == 256;
}

/// What "Read card" found. Everything that could be read is kept, even when the reading failed.
class CardReadResult {
  CardReadResult({
    required this.image,
    required this.blocks,
    required this.platform,
    required this.time,
    required this.seconds,
    required this.commands,
    this.expected = defaultSize,
    this.moreThanExpected = false,
    this.moreDetail,
    this.error,
    this.cardId,
    this.warnings = const [],
  });

  /// The EMG card's size, used as the default and for labels before a read has happened.
  static const defaultSize = 32768; // EF 3040: offsets 0000-7FFF
  static const defaultBlockCount = defaultSize ~/ 256;

  /// How many bytes this read was for (the card profile's file size).
  final int expected;
  int get blockCount => (expected + 255) ~/ 256;

  final Uint8List image; // `expected` bytes; bytes that were not read are 00
  final List<BlockRead> blocks; // the blocks of the file
  final PhonePlatform platform;
  final DateTime time;
  final double seconds;
  final int commands;
  final bool moreThanExpected; // the card gave data past 7FFF
  final String? moreDetail;
  final String? error; // why the reading could not start at all
  final Uint8List? cardId;
  final List<String> warnings; // things that went wrong but did not stop the reading

  int get bytesRead => blocks.fold(0, (sum, b) => sum + b.bytes);
  bool get ok => error == null && !moreThanExpected && bytesRead == expected;
  double get kbPerSecond => seconds > 0 ? bytesRead / 1024 / seconds : 0;

  /// The bytes that were read, in offset order (unread parts left out).
  Uint8List get dataRead {
    final b = BytesBuilder(copy: false);
    for (final block in blocks) {
      if (block.bytes > 0) b.add(Uint8List.sublistView(image, block.start, block.start + block.bytes));
    }
    return b.toBytes();
  }

  int get crc => crc32(dataRead);

  /// True when byte [offset] was read.
  bool wasRead(int offset) {
    final block = offset >> 8;
    return block < blocks.length && (offset - blocks[block].start) < blocks[block].bytes;
  }

  /// The parts that were not read, joined when they touch and have the same reason: (first offset, last offset, reason).
  List<(int, int, String)> get missing {
    final out = <(int, int, String)>[];
    for (final b in blocks) {
      if (b.complete) continue;
      final from = b.start + b.bytes, to = b.start + 255;
      final why = _reasonOnly(b.problem ?? 'not read');
      if (out.isNotEmpty && out.last.$2 + 1 == from && out.last.$3 == why) {
        out[out.length - 1] = (out.last.$1, to, why);
      } else {
        out.add((from, to, why));
      }
    }
    return out;
  }

  /// "6F 00 (No precise diagnosis) at 7F00" -> "6F 00 (No precise diagnosis)", so neighbouring blocks can be joined.
  static String _reasonOnly(String problem) => problem.replaceFirst(RegExp(r' at [0-9A-F]{4}$'), '');

  /// The one-line result, used by the screen and the report.
  String get message {
    if (error != null) return 'EXCEPTION: $error';
    if (moreThanExpected) {
      return 'EXCEPTION: the card has MORE than $expected bytes. All $expected bytes were read, and the card still gives '
          'data past 7FFF ($moreDetail).';
    }
    if (bytesRead == expected) {
      final kb = (expected / 1024).toStringAsFixed(expected % 1024 == 0 ? 0 : 1);
      return 'OK: the whole card was read, $expected bytes ($kb KB, offsets 0000-${h4(expected - 1)})'
          '${warnings.isEmpty ? '.' : ', with ${warnings.length} warning${warnings.length == 1 ? '' : 's'}.'}';
    }
    final parts = missing;
    final shown = parts.take(3).map((m) => '${h4(m.$1)}-${h4(m.$2)}: ${m.$3}').join('; ');
    final more = parts.length > 3 ? '; and ${parts.length - 3} more parts' : '';
    return 'EXCEPTION: only $bytesRead of $expected bytes were read (${expected - bytesRead} not read). '
        'Not read: $shown$more.';
  }

  /// 'data', '00', 'FF' for complete blocks; 'partial' or 'missing' for blocks that were not fully read.
  List<String> get blockKinds => [
        for (final b in blocks)
          if (b.bytes == 0)
            'missing'
          else if (!b.complete)
            'partial'
          else
            _kind(b.start),
      ];

  String _kind(int start) {
    var zero = true, ff = true;
    for (var i = start; i < start + 256; i++) {
      if (image[i] != 0x00) zero = false;
      if (image[i] != 0xFF) ff = false;
      if (!zero && !ff) return 'data';
    }
    return zero ? '00' : 'FF';
  }
}

/// Reads the whole card the way a phone app would, and keeps going when something fails:
/// - tap; SELECT the applet by AID, GET UID and SELECT EF 3040 (a failure there is a warning: the card's default applet
///   may still answer);
/// - READ BINARY every 256-byte block from 0000 to 7FFF. A block that fails is marked with its status word and the
///   reading goes on with the next block. A block that fails with an unexpected status is read again in 16-byte parts,
///   to save what can be read. A 6C xx answer is read again with Le = xx.
/// - if the card stops answering, it taps once more and goes on; if that fails, everything read so far is kept;
/// - after 32768 bytes, READ 7FFF with Le 02 shows whether the card has data past 7FFF.
/// Nothing is written to the card.
class CardReader {
  CardReader(this.s, this.log, {this.onProgress, Uint8List? appletAid, CardProfile? profile})
      : appletAid = appletAid ?? AppletAid.byDefault,
        profile = profile ?? CardProfile.emg,
        _image = Uint8List((profile ?? CardProfile.emg).fileSize),
        _blocks = List<BlockRead>.generate((profile ?? CardProfile.emg).blockCount, BlockRead.new);

  /// The applet this read selects, from the AID box, so a freshly burned applet is read rather than the old one.
  final Uint8List appletAid;

  /// How this card is talked to: which file to select, how to read, how big it is.
  final CardProfile profile;

  String get _selectApplet => AppletAid.select(appletAid);
  String get _aidText => Hex.of(appletAid);

  final PhoneSession s;
  final Logger log;
  final void Function(int bytesRead)? onProgress;

  final Uint8List _image;
  final List<BlockRead> _blocks;
  final _warnings = <String>[];
  var _commands = 0;
  var _retaps = 0;
  var _salvaged = 0; // blocks read again in small parts
  Uint8List? _cardId;

  Future<CardReadResult> run() async {
    final watch = Stopwatch()..start();
    var more = false;
    String? moreDetail;

    CardReadResult result({String? error}) => CardReadResult(
          image: _image,
          blocks: _blocks,
          platform: s.platform,
          time: DateTime.now(),
          seconds: watch.elapsedMicroseconds / 1e6,
          commands: _commands,
          expected: profile.fileSize,
          moreThanExpected: more,
          moreDetail: moreDetail,
          error: error,
          cardId: _cardId,
          warnings: List.of(_warnings),
        );

    log.section('Read card as an ${s.platform.app}');
    try {
      if (!await s.tap()) {
        final why = s.platform == PhonePlatform.iphone
            ? 'the iPhone did not find the card: no AID of the app list answered 90 00 (see the log). '
                'An iPhone app cannot read this card with this AID list.'
            : 'the Android phone did not find an ISO-DEP card.';
        for (final b in _blocks) {
          b.problem = 'the phone did not find the card';
        }
        return result(error: why);
      }
      await _prepare();
    } on CardException catch (e) {
      for (final b in _blocks) {
        b.problem = e.message;
      }
      return result(error: 'the card could not be reached: ${e.message}');
    }

    for (final b in _blocks) {
      try {
        await _readBlock(b);
      } on CardException catch (e) {
        log.warn('Block ${h2(b.index)}: ${e.message}');
        if (await _recover('the card stopped answering at ${h4(b.start + b.bytes)}')) {
          try {
            await _readBlock(b);
          } on CardException catch (e2) {
            b.problem ??= e2.message;
          }
        }
        if (!s.active) {
          // the card is gone and could not be found again: keep what was read and mark the rest
          for (final rest in _blocks.where((x) => x.index >= b.index && !x.complete)) {
            rest.problem ??= 'not read: ${e.message}';
          }
          _warnings.add('The card stopped answering at ${h4(b.start + b.bytes)} and could not be found again.');
          break;
        }
      }
      onProgress?.call(_blocks.fold(0, (sum, x) => sum + x.bytes));
    }

    final total = _blocks.fold(0, (sum, x) => sum + x.bytes);
    if (total == profile.fileSize) {
      try {
        // ask for 2 bytes at the last offset: if the card gives more than the one byte that is there, the file is bigger
        final last = profile.lastOffset;
        final probe = await _send(profile.readCommand(last, 2), 'Read card: data past ${h4(last)}?');
        if (probe.ok && probe.response!.sw == 0x9000 && probe.response!.data.length > 1) {
          more = true;
          moreDetail = 'READ ${h4(last)} with Le 02 returned ${probe.response!.data.length} bytes';
        } else {
          log.info('READ ${h4(last)} with Le 02 answered ${probe.short}: the file ends at ${h4(last)}.');
        }
      } on CardException catch (e) {
        _warnings.add('The check for data past the end could not run: ${e.message}');
      }
    }

    final res = result();
    log.info('Read card: ${res.bytesRead} bytes in ${res.seconds.toStringAsFixed(2)} s, '
        'CRC-32 ${res.crc.toRadixString(16).padLeft(8, '0').toUpperCase()}. ${res.message}');
    for (final w in res.warnings) {
      log.warn(w);
    }
    return res;
  }

  /// SELECT the applet, GET UID, SELECT EF 3040. A failure is only a warning: the card's default applet may still answer.
  Future<void> _prepare() async {
    var r = await _send(_selectApplet, 'Read card: SELECT applet');
    if (r.status == SendStatus.blocked) {
      _warnings.add('SELECT of the applet by its AID ($_aidText) was not sent: iOS blocks it, because this AID is not '
          "in the app's AID list. The reading went on with the applet that answered at the tap "
          '(initialSelectedAID ${s.initialSelectedAid}).');
    } else if (!(r.ok && r.response!.sw == 0x9000)) {
      _warnings.add('SELECT of the applet by its AID ($_aidText) answered ${_answer(r)}: no applet answers to this AID. '
          'The reading went on with the applet the card selects by itself (its default applet).');
    }
    if (profile.hasIdCommand) {
      r = await _send(profile.idCommand, 'Read card: card ID');
      if (r.ok && r.response!.sw == 0x9000 && r.response!.data.isNotEmpty) {
        _cardId = r.response!.data;
      } else {
        _warnings.add('The card ID command (${profile.idCommand}) answered ${_answer(r)}.');
      }
    }
    if (profile.hasSelectFile) {
      r = await _send(profile.selectFile, 'Read card: SELECT file');
      if (!(r.ok && r.response!.sw == 0x9000)) {
        _warnings.add('SELECT file (${profile.selectFile}) answered ${_answer(r)}. The reading was tried anyway.');
      }
    }
  }

  /// Reads one block. Every failure is noted in the block, never thrown, except when the card stops answering.
  Future<void> _readBlock(BlockRead b) async {
    final end = b.start + 256;
    var pos = b.start + b.bytes;
    var guard = 0; // every pass either stores bytes or returns; this only protects against a card that misbehaves
    while (pos < end && guard++ < 300) {
      final le = end - pos;
      final r = await _read(pos, le, 'Read card');
      if (r == null) return; // noted in the block
      if (r.ok && r.response!.sw == 0x9000 && r.response!.data.isNotEmpty) {
        pos = _store(b, pos, r.response!.data, end);
        continue;
      }
      if (r.ok && r.response!.sw1 == 0x6C) {
        final xx = r.response!.sw2 == 0 ? 256 : r.response!.sw2;
        if (xx < le) {
          final r2 = await _read(pos, xx, 'Read card: Le = ${h2(xx & 0xFF)} as the card asked');
          if (r2 != null && r2.ok && r2.response!.sw == 0x9000 && r2.response!.data.isNotEmpty) {
            pos = _store(b, pos, r2.response!.data, end);
            continue; // the next READ shows why the rest of the block cannot be read
          }
        }
      }
      // this READ failed: with an unexpected answer, save what can be read in 16-byte parts
      final answer = _answer(r);
      if (_worthSalvage(r) && _salvaged < 8 && pos % 16 == 0) {
        _salvaged++;
        final before = pos;
        pos = await _salvage(b, pos, end);
        if (pos > before) {
          log.info('Block ${h2(b.index)}: ${pos - before} more bytes saved by reading 16 bytes at a time.');
          _warnings.add('Block ${h2(b.index)}: READ of ${end - before} bytes at ${h4(before)} answered $answer, '
              'so it was read 16 bytes at a time (${pos - before} bytes saved).');
        }
      }
      if (pos < end) b.problem = '$answer at ${h4(pos)}';
      return;
    }
    if (pos < end) b.problem ??= 'not read';
  }

  /// Reads [from]..[end] 16 bytes at a time, and stops at the first part that fails. Returns how far it got.
  Future<int> _salvage(BlockRead b, int from, int end) async {
    var pos = from;
    while (pos < end) {
      final n = end - pos < 16 ? end - pos : 16;
      final r = await _read(pos, n, 'Read card: 16 bytes at a time');
      if (r == null || !(r.ok && r.response!.sw == 0x9000 && r.response!.data.isNotEmpty)) break;
      pos = _store(b, pos, r.response!.data, end);
    }
    return pos;
  }

  /// One READ BINARY; null when the iPhone session ended and could not be started again (noted in the block).
  Future<SendResult?> _read(int pos, int le, String label) async {
    final cmd = profile.readCommand(pos, le);
    var r = await _send(cmd, label);
    if (r.status == SendStatus.expired || r.status == SendStatus.noCard) {
      // on an iPhone the session ends after 60 s: the user taps again and the app goes on
      if (!await _recover('the ${s.platform.short} session ended at ${h4(pos)}')) {
        _blocks[pos >> 8].problem = r.reason;
        return null;
      }
      r = await _send(cmd, label);
    }
    return r;
  }

  int _store(BlockRead b, int pos, Uint8List data, int end) {
    final n = data.length < end - pos ? data.length : end - pos;
    _image.setRange(pos, pos + n, data);
    b.bytes = pos + n - b.start;
    return pos + n;
  }

  /// A new tap, then SELECT applet and SELECT EF 3040 again. At most 3 times per read.
  Future<bool> _recover(String why) async {
    if (_retaps >= 3) return false;
    _retaps++;
    _warnings.add('${why[0].toUpperCase()}${why.substring(1)}; the card was tapped again ($_retaps).');
    log.warn('Read card: $why. Tapping again.');
    try {
      if (!await s.tap()) return false;
      await _send(_selectApplet, 'Read card: SELECT applet (again)');
      if (!profile.hasSelectFile) return true;
      final r = await _send(profile.selectFile, 'Read card: SELECT file (again)');
      return r.ok;
    } on CardException catch (e) {
      log.warn('Read card: the card could not be found again: ${e.message}');
      s.end();
      return false;
    }
  }

  Future<SendResult> _send(String hex, String label) async {
    _commands++;
    return s.sendHex(hex, label);
  }

  /// Small parts may work when a whole block fails with an internal or length error; not for "no file" or "bad offset".
  static bool _worthSalvage(SendResult r) {
    if (!r.ok) return false;
    final sw = r.response!.sw;
    return sw == 0x6F00 || sw == 0x6700 || (sw >> 8) == 0x6C || (sw >> 8) == 0x64 || (sw >> 8) == 0x65;
  }

  static String _answer(SendResult r) =>
      r.ok ? '${r.response!.swText} (${explainAnswer(r.sent ?? r.typed, r.response!.sw).short})' : r.short;
}
