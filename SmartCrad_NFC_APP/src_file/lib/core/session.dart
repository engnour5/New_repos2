import 'dart:typed_data';

import '../card/card_channel.dart';
import 'apdu.dart';
import 'atr_info.dart';
import 'errors.dart';
import 'hex.dart';
import 'ios_rules.dart';
import 'log.dart';
import 'platform.dart';

enum SendStatus { sent, blocked, invalid, readerCommand, noCard, expired }

class SendResult {
  SendResult(this.typed);

  final Uint8List typed;
  SendStatus status = SendStatus.sent;
  Uint8List? sent;
  ResponseApdu? response;
  double ms = 0;
  String? reason;

  bool get ok => status == SendStatus.sent;
  int get sw => response?.sw ?? -1;

  /// "90 00" for a sent command, otherwise why it was not sent.
  String get short {
    if (ok) return response!.swText;
    return switch (status) {
      SendStatus.blocked => 'blocked by iOS',
      SendStatus.invalid => 'invalid APDU',
      SendStatus.readerCommand => 'reader command, not on a phone',
      SendStatus.noCard => 'no card in the session',
      _ => 'session over (60 s)',
    };
  }
}

/// One phone reader session on a PC/SC reader or the simulator: a tap, the phone's own discovery, then the app's
/// commands under the phone's rules.
/// - iPhone (Core NFC, NFCTagReaderSession): automatic SELECT of the Info.plist AIDs, SELECT by AID only for listed AIDs,
///   payment AIDs blocked, APDU rebuilt from its fields, 60 s per session.
/// - Android (IsoDep): an NDEF check at discovery, then any bytes go to the card as typed, no session limit.
class PhoneSession {
  PhoneSession(this.channel, this.rules, this.log, {this.platform = PhonePlatform.iphone});

  static const iosLimitSeconds = 60; // iOS ends a reader session after 60 s

  /// SELECT of the NFC Forum NDEF Tag Application, which Android sends to look for NDEF data.
  static final ndefCheck = Hex.parse('00A4040007D276000085010100');

  final CardChannel channel;
  IosRules rules;
  PhonePlatform platform;
  final Logger log;

  /// Called when a tap starts and when it ends (true = the app got the card). The screens use them for the animation.
  void Function()? onTapStart;
  void Function(bool detected)? onTapDone;

  final Stopwatch _clock = Stopwatch();
  double _addedSeconds = 0; // used by the tests to age a session

  bool active = false;
  bool detected = false;
  String? initialSelectedAid;
  int taps = 0;

  double get elapsed => active ? _clock.elapsedMicroseconds / 1e6 + _addedSeconds : 0;
  bool get expired => platform.hasSessionLimit && active && elapsed > iosLimitSeconds;

  void end() {
    active = false;
    detected = false;
    _clock
      ..stop()
      ..reset();
  }

  void ageForTest(double seconds) => _addedSeconds += seconds;

  /// The bytes of the automatic SELECT that iOS sends for one list entry (assumed form: with Le 00).
  static Uint8List discoverySelect(Uint8List aid) => Hex.concat([
        [0x00, 0xA4, 0x04, 0x00, aid.length],
        aid,
        [0x00],
      ]);

  /// A tap: the field goes off and on, then the phone discovers the card. Returns false when the app would not get it.
  Future<bool> tap() async {
    end();
    _addedSeconds = 0;
    taps++;
    onTapStart?.call();
    if (platform == PhonePlatform.iphone) {
      log.info('Tap $taps: RF field off and on, as when the card comes to the iPhone. '
          'A new reader session starts; iOS ends it after $iosLimitSeconds s.');
    } else {
      log.info('Tap $taps: RF field off and on, as when the card touches the back of the Android phone.');
    }
    try {
      await channel.fieldReset();
      _clock
        ..reset()
        ..start();
      active = true;
      final found = platform == PhonePlatform.iphone ? await _iosDiscovery() : await _androidDiscovery();
      onTapDone?.call(found);
      return found;
    } on CardException {
      end();
      onTapDone?.call(false);
      rethrow;
    }
  }

  /// iOS selects the listed AIDs in order. The first one that answers 90 00 becomes initialSelectedAID.
  Future<bool> _iosDiscovery() async {
    var tried = 0;
    for (final e in rules.entries) {
      if (!e.usable) {
        log.warn('iOS skips the list entry ${e.text}: ${e.problem}');
        continue;
      }
      tried++;
      final select = discoverySelect(e.aid!);
      final watch = Stopwatch()..start();
      final r = ResponseApdu.fromRaw(await channel.transmit(select));
      log.exchange('iOS automatic SELECT', select, r, watch.elapsedMicroseconds / 1000);
      if (r.sw == 0x9000) {
        detected = true;
        initialSelectedAid = Hex.compact(e.aid);
        log.info('iOS gives the card to the app as an ISO 7816 tag. initialSelectedAID = $initialSelectedAid');
        return true;
      }
    }
    if (tried == 0) {
      log.warn('The AID list has no usable entry. iOS ends the session with NFCReaderErrorSecurityViolation.');
    } else {
      log.warn('No AID of the list answered 90 00, so iOS does not give this card to the app as an ISO 7816 tag.');
    }
    return false;
  }

  /// Android needs no AID: an ISO-DEP card becomes an IsoDep object. The NFC service first looks for NDEF data.
  Future<bool> _androidDiscovery() async {
    final info = AtrInfo.parse(channel.atr);
    if (!channel.isSimulated && !info.isoDep && info.contactlessFormat) {
      log.warn('The card is not ISO-DEP, so Android gives the app no IsoDep object and no APDUs can be sent.');
      return false;
    }
    final watch = Stopwatch()..start();
    final r = ResponseApdu.fromRaw(await channel.transmit(ndefCheck));
    log.exchange('Android NDEF check', ndefCheck, r, watch.elapsedMicroseconds / 1000);
    if (r.sw == 0x9000) {
      log.info('The card has an NDEF application. Android reads its NDEF data, then gives the card to the app as IsoDep.');
    } else {
      log.info('No NDEF data (${r.swText}). Android gives the card to the app as IsoDep; no AID is needed.');
    }
    detected = true;
    initialSelectedAid = null;
    return true;
  }

  Future<SendResult> sendHex(String hex, String label) => send(Hex.parse(hex), label);

  /// What the app's send call does: iOS sendCommand(apdu:) or Android IsoDep.transceive().
  Future<SendResult> send(Uint8List typed, String label) async {
    final result = SendResult(typed);
    if (platform == PhonePlatform.android) return _sendAndroid(result, label);

    final (c, error) = CommandApdu.parse(typed);
    if (c == null) {
      return _notSent(result, SendStatus.invalid, 'iOS cannot build an NFCISO7816APDU from these bytes: $error', label);
    }
    if (c.cla == 0xFF) {
      return _notSent(
          result,
          SendStatus.readerCommand,
          'CLA FF is a PC/SC reader command (FF CA = get UID). A PC reader answers it itself, but an iPhone has no such '
          'layer. An iPhone app reads the UID from tag.identifier.',
          label);
    }
    if (!active || !detected) {
      return _notSent(result, SendStatus.noCard, 'no card in this iPhone session. Tap first; one AID of the list must answer 90 00.', label);
    }
    if (expired) {
      return _notSent(result, SendStatus.expired, 'the iPhone session is over: iOS ends a reader session after $iosLimitSeconds s. Tap again.', label);
    }
    final rule = rules.checkSelect(c);
    if (rule != null) return _notSent(result, SendStatus.blocked, rule, label);

    final wire = c.encode();
    await _transmit(result, wire, label);
    if (!Hex.same(wire, typed)) {
      log.info('iOS sent it as ${Hex.of(wire)}: Core NFC builds the bytes from CLA, INS, P1, P2, data and Le.');
    }
    return result;
  }

  /// IsoDep.transceive(): the bytes go to the card exactly as typed. Android checks no SELECT and blocks no AID.
  Future<SendResult> _sendAndroid(SendResult result, String label) async {
    final typed = result.typed;
    if (typed.length < 4) return _notSent(result, SendStatus.invalid, 'an APDU needs at least 4 bytes (CLA INS P1 P2).', label);
    if (typed[0] == 0xFF) {
      return _notSent(
          result,
          SendStatus.readerCommand,
          'CLA FF is a PC/SC reader command (FF CA = get UID). An Android phone has no such layer: the bytes would go to '
          'the card. An Android app reads the UID from Tag.getId().',
          label);
    }
    if (!active || !detected) {
      return _notSent(result, SendStatus.noCard, 'no card: tap first, so Android gives the card to the app as IsoDep.', label);
    }
    if (typed.length > 261) {
      log.warn('This command is ${typed.length} bytes. Many Android phones send at most 261 bytes '
          '(IsoDep.getMaxTransceiveLength); longer commands need extended-length support.');
    }
    await _transmit(result, typed, label);
    return result;
  }

  Future<void> _transmit(SendResult result, Uint8List wire, String label) async {
    final watch = Stopwatch()..start();
    Uint8List raw;
    try {
      raw = await channel.transmit(wire);
    } on CardException {
      end(); // on a phone the tag connection is lost
      rethrow;
    }
    result
      ..ms = watch.elapsedMicroseconds / 1000
      ..sent = wire
      ..response = ResponseApdu.fromRaw(raw)
      ..status = SendStatus.sent;
    log.exchange(label, wire, result.response!, result.ms);
  }

  SendResult _notSent(SendResult result, SendStatus status, String reason, String label) {
    result
      ..status = status
      ..reason = reason;
    log.blocked(label, result.typed, reason);
    return result;
  }
}
