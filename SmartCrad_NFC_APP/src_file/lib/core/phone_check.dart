import 'dart:typed_data';

import 'applet.dart';
import 'atr_info.dart';
import 'error_map.dart';
import 'hex.dart';
import 'platform.dart';
import 'session.dart';

class StepRow {
  StepRow(this.step, this.result, this.details);

  final String step;
  final String result; // OK, WARN, FAIL, INFO, BLOCKED
  final String details;
}

/// The one-click, read-only check: is the card an ISO-DEP card, does the phone find it, and do the applet's commands
/// work under the phone's rules within one session.
class PhoneCheck {
  PhoneCheck(this.onRow, {Uint8List? appletAid}) : appletAid = appletAid ?? AppletAid.byDefault;

  /// The applet this check looks for, from the AID box.
  final Uint8List appletAid;

  final void Function(StepRow row)? onRow;
  final List<StepRow> rows = [];
  String verdict = '';
  bool yes = false;
  int warnings = 0;

  void _add(String step, String result, String details) {
    final row = StepRow(step, result, details);
    rows.add(row);
    onRow?.call(row);
  }

  Future<void> run(PhoneSession s) async {
    final ch = s.channel;
    final p = s.platform;
    final ios = p == PhonePlatform.iphone;
    var fail = false;

    final contactlessReader = ch.isSimulated || AtrInfo.looksContactless(ch.name);
    if (ch.isSimulated) {
      _add('Reader', 'INFO', '${ch.name}. It answers like your test card: the EMG applet is the default applet.');
    } else {
      _add('Reader', contactlessReader ? 'OK' : 'WARN',
          ch.name + (contactlessReader ? '' : '. The name does not say contactless. A phone reads cards only over NFC (contactless).'));
    }

    await ch.connect();
    final atr = AtrInfo.parse(ch.atr);
    final atrText = ch.atr == null ? 'no ATR' : Hex.of(ch.atr);
    if (atr.isoDep) {
      _add('Card type (ATR)', 'OK', '$atrText  ->  ${atr.description}');
    } else if (atr.storage || !contactlessReader) {
      _add('Card type (ATR)', 'FAIL', '$atrText  ->  ${atr.description}');
      fail = true;
    } else {
      _add('Card type (ATR)', 'WARN', '$atrText  ->  not in the PC/SC contactless format, so the card type cannot be read from it.');
    }

    final uid = await ch.getUid();
    _add(ios ? 'UID (iOS: tag.identifier)' : 'UID (Android: Tag.getId())', 'INFO',
        uid == null ? 'the reader did not give a UID' : '${Hex.of(uid)}${_uidNote(uid)}');
    final hist = atr.historical;
    if (hist != null && hist.isNotEmpty) {
      final ascii = Hex.ascii(hist);
      _add(ios ? 'Historical bytes (iOS: tag.historicalBytes)' : 'Historical bytes (Android: IsoDep.getHistoricalBytes())', 'INFO',
          Hex.of(hist) + (ascii != null ? '   "$ascii"' : ''));
    }

    if (ios) {
      if (s.rules.entries.isEmpty) {
        _add('App AID list', 'FAIL', 'empty. The app must list at least one AID in Info.plist.');
        fail = true;
      }
      for (final e in s.rules.entries) {
        if (!e.usable) {
          _add('App AID list: ${e.text}', 'BLOCKED', e.problem!);
        } else if (e.warning != null) {
          _add('App AID list: ${e.text}', 'WARN', e.warning!);
        } else {
          _add('App AID list: ${e.text}', 'OK', e.kind ?? '');
        }
      }
    } else {
      _add('App AID list', 'INFO', 'not needed on Android: IsoDep sends any APDU, and any app with the NFC permission can use it.');
    }

    final detected = await s.tap();
    if (ios) {
      if (detected) {
        _add('Tap: iOS automatic SELECT', 'OK',
            'the card answered 90 00 to ${s.initialSelectedAid}, so iOS gives it to the app (initialSelectedAID).');
      } else {
        _add('Tap: iOS automatic SELECT', 'FAIL', 'no AID of the list answered 90 00, so the app never gets this card.');
        fail = true;
      }
    } else {
      if (detected) {
        _add('Tap: Android finds the card', 'OK', 'Android checked for NDEF data (none), then gave the card to the app as IsoDep.');
      } else {
        _add('Tap: Android finds the card', 'FAIL', 'the card is not ISO-DEP, so the app gets no IsoDep object.');
        fail = true;
      }
    }

    final applet = detected && (!ios || s.initialSelectedAid == Hex.compact(appletAid));
    if (applet) {
      if (!await _step(s, 'App sends: SELECT applet by AID', AppletAid.select(appletAid), 0x9000, -1)) fail = true;
      if (!await _step(s, 'App sends: GET UID', '80 08 00 00 0A', 0x9000, 10)) fail = true;
      if (!await _step(s, 'App sends: SELECT EF 3040', '00 A4 00 00 02 30 40', 0x9000, -1)) fail = true;
      if (!await _step(s, 'App sends: READ 256 bytes (Le 00)', '00 B0 00 00 00', 0x9000, 256)) fail = true;
      const other = '00 A4 04 00 05 A0 00 00 09 99';
      final r = await s.sendHex(other, 'SELECT an AID outside the list');
      if (ios) {
        _add('App sends: SELECT an AID outside the list', 'INFO', r.status == SendStatus.blocked
            ? '$other  ->  blocked by iOS before it reaches the card, as expected: an app can only select AIDs from its list.'
            : '$other  ->  ${describe(r)}');
      } else {
        _add('App sends: SELECT another AID', 'INFO', '$other  ->  ${describe(r)}. Android lets the app select any AID.');
      }
    } else if (detected) {
      _add('Applet commands', 'INFO', 'skipped: the selected AID is not the EMG applet.');
    }

    final t = s.elapsed;
    if (ios) {
      _add('Session time', t <= PhoneSession.iosLimitSeconds ? 'OK' : 'FAIL',
          '${t.toStringAsFixed(2)} s used of the ${PhoneSession.iosLimitSeconds} s that iOS allows per session '
          '(an iPhone may be slower than this reader).');
      if (t > PhoneSession.iosLimitSeconds) fail = true;
    } else {
      _add('Session time', 'INFO', '${t.toStringAsFixed(2)} s. Android has no session limit; each command has a timeout (IsoDep.setTimeout).');
    }

    warnings = rows.where((r) => r.result == 'WARN').length;
    yes = !fail;
    final who = 'an ${p.app}';
    if (fail) {
      verdict = 'NO: $who would not work with this card. See the red rows.';
    } else if (warnings > 0) {
      verdict = 'YES, with $warnings ${warnings == 1 ? 'warning' : 'warnings'}: $who${ios ? ' with this AID list' : ''} should work.';
    } else {
      verdict = 'YES: $who${ios ? ' with this AID list' : ''} can find this card and use the applet.';
    }
  }

  Future<bool> _step(PhoneSession s, String name, String apdu, int expectedSw, int expectedLength) async {
    final r = await s.sendHex(apdu, name);
    final ok = r.ok && r.response!.sw == expectedSw && (expectedLength < 0 || r.response!.data.length == expectedLength);
    _add(name, ok ? 'OK' : 'FAIL', '$apdu  ->  ${describe(r)}');
    return ok;
  }

  static String describe(SendResult r) {
    if (!r.ok) return 'not sent, ${r.reason}';
    final resp = r.response!;
    final n = resp.data.length;
    final data = n == 0 ? '' : (n <= 16 ? '${Hex.of(resp.data)}  ' : '$n bytes  ');
    return '$data${resp.swText} ${explainAnswer(r.sent ?? r.typed, resp.sw).short}  (${r.ms.toStringAsFixed(1)} ms)';
  }

  static String _uidNote(List<int> uid) {
    if (uid.length == 4 && uid[0] == 0x08) {
      return '  (random UID: it changes at every tap, so an app must use GET UID 80 08 as the card ID)';
    }
    if (uid.length == 7) return '  (7-byte UID)';
    if (uid.length == 4) return '  (4-byte UID)';
    return '';
  }
}
