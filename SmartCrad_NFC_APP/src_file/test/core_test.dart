// The logic on the built-in simulator: APDU parsing, the iPhone and Android rules, the phone check,
// the card unit test (card_test.ps1 checks, extra checks, card size) and the HTML report.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/card_channel.dart';
import 'package:iphone_nfc_tester/card/simulated_card.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/card_reader.dart';
import 'package:iphone_nfc_tester/core/card_test.dart';
import 'package:iphone_nfc_tester/core/data_report.dart';
import 'package:iphone_nfc_tester/core/error_map.dart';
import 'package:iphone_nfc_tester/core/errors.dart';
import 'package:iphone_nfc_tester/core/guide.dart';
import 'package:iphone_nfc_tester/core/guide_html.dart';
import 'package:iphone_nfc_tester/ui/pages/home_page.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/ios_rules.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/core/phone_check.dart';
import 'package:iphone_nfc_tester/core/platform.dart';
import 'package:iphone_nfc_tester/core/report.dart';
import 'package:iphone_nfc_tester/core/session.dart';

class _QuietLog implements Logger {
  final lines = <String>[];

  @override
  void section(String text) => lines.add('=== $text');

  @override
  void info(String text) => lines.add(text);

  @override
  void warn(String text) => lines.add('! $text');

  @override
  void exchange(String label, Uint8List sent, ResponseApdu response, double ms) =>
      lines.add('>> ${Hex.of(sent)} [$label] << ${response.swText}');

  @override
  void blocked(String label, Uint8List typed, String reason) => lines.add('>> ${Hex.of(typed)} [$label] NOT SENT');
}

const emg = '454D4730303030303030';

/// The simulator, with some answers replaced: used to make cards that are shorter or longer than 32 KB.
class _ChangedCard implements CardChannel {
  _ChangedCard(this.answer);

  final SimulatedCard inner = SimulatedCard(delay: Duration.zero);
  final Uint8List? Function(String apdu) answer;

  /// When true, the card is gone: every command and every tap fails, as when it is taken off the reader.
  bool removed = false;

  /// Every command that reached the card.
  final sent = <String>[];

  @override
  String get name => 'changed simulator';

  @override
  bool get isSimulated => true;

  @override
  Uint8List? get atr => inner.atr;

  @override
  Future<void> connect() => inner.connect();

  @override
  Future<void> fieldReset() async {
    if (removed) throw CardException('There is no card on the reader.');
    await inner.fieldReset();
  }

  @override
  Future<Uint8List> transmit(Uint8List apdu) async {
    if (removed) throw CardException('The card was removed.');
    final hex = Hex.of(apdu);
    final changed = answer(hex);
    sent.add(hex);
    return changed ?? await inner.transmit(apdu);
  }

  @override
  Future<Uint8List?> getUid() => inner.getUid();

  @override
  Future<void> disconnect() => inner.disconnect();

  @override
  Future<void> dispose() => inner.dispose();
}

/// The ORIGINAL applet (review\gas_electrometer_original.java, the old .cap) as the default applet, as on the test
/// card after the old .cap was loaded again: the cases of process() fall through, nothing checks a length, an array
/// copy outside mainBuffer gives 6F 00, and the file flag is a static field, so a reset does not clear it.
class _OriginalAppletCard implements CardChannel {
  _OriginalAppletCard() {
    for (var i = 0; i < main.length; i++) {
      main[i] = (i * 13 + 7) & 0xFF;
    }
    extra[0] = 0x3C;
    cardUid.setAll(0, Hex.parse('DF AD 88 29 EF 89 90 63 A2 97'));
  }

  static final _ownAid = Hex.parse('67 61 73 65 6C 65 63 74'); // not the EMG AID
  final main = Uint8List(32767);
  final extra = Uint8List(1);
  final cardUid = Uint8List(10);
  final _buf = Uint8List(261); // the APDU buffer
  final sent = <String>[];
  bool _fileSelected = false;
  bool _powered = false;

  @override
  String get name => 'original applet';

  @override
  bool get isSimulated => true;

  @override
  Uint8List? get atr => Hex.parse('3B 89 80 01 00 31 C1 73 C8 40 00 00 90 93');

  @override
  Future<void> connect() async => _powered = true;

  @override
  Future<void> fieldReset() async => _powered = true;

  @override
  Future<Uint8List?> getUid() async => null;

  @override
  Future<void> disconnect() async => _powered = false;

  @override
  Future<void> dispose() async {}

  @override
  Future<Uint8List> transmit(Uint8List a) async {
    if (!_powered) throw CardException('The card is not powered.');
    sent.add(Hex.of(a));
    // the card OS selects the applet by its own AID; any other SELECT by AID goes to process() of the default applet
    if (a.length > 5 && a[0] == 0x00 && a[1] == 0xA4 && a[2] == 0x04 && a.length >= 5 + a[4] &&
        Hex.same(Hex.sub(a, 5, a[4]), _ownAid)) {
      return _sw(0x9000);
    }
    // the real card reads 00 after the command bytes (C16 "00 A4 00 00 01 3F" answered 90 00: 3F 00 = MF)
    _buf
      ..fillRange(0, _buf.length, 0)
      ..setRange(0, a.length, a);
    try {
      return _process();
    } on _OutOfBounds {
      return _sw(0x6F00); // ArrayIndexOutOfBoundsException, not caught by the applet
    }
  }

  Uint8List _process() {
    final cla = _buf[0], ins = _buf[1];
    final start = switch (ins) { 0xA4 => 0, 0x08 => 1, 0xD6 => 2, 0xB0 => 3, _ => 4 };
    int offset() => _short(((_buf[2] << 8) & 0xFFFF) + _buf[3]);
    if (start <= 0 && cla == 0x00) {
      _fileSelected = false;
      if (_buf[5] == 0x3F && _buf[6] == 0x00) return _sw(0x9000);
      if (_buf[5] == 0x30 && _buf[6] == 0x40) {
        _fileSelected = true;
        return _sw(0x9000);
      }
      return _sw(0x6D00);
    }
    if (start <= 1 && cla == 0x80) return Hex.concat([cardUid, _sw(0x9000)]);
    if (start <= 2 && cla == 0x00) {
      if (!_fileSelected) return _sw(0x6D00);
      final total = _buf[4], at = offset();
      if (_short(at - 1 + total) == 32767) {
        _copy(_buf, 5, main, at, total - 1);
        _copy(_buf, 5 + total - 1, extra, 0, 1);
      } else {
        _copy(_buf, 5, main, at, total);
      }
      return _sw(0x9000);
    }
    if (start <= 3 && cla == 0x00) {
      if (!_fileSelected) return _sw(0x6D00);
      var total = _buf[4];
      final at = offset();
      if (total == 0) total = 256;
      if (_short(at - 1 + total) == 32767) {
        _copy(extra, 0, _buf, total - 1, 1);
        _copy(main, at, _buf, 0, total - 1);
      } else {
        _copy(main, at, _buf, 0, total);
      }
      return Hex.concat([Hex.sub(_buf, 0, total), _sw(0x9000)]);
    }
    return _sw(0x6D00);
  }

  static int _short(int v) => (v & 0xFFFF) >= 0x8000 ? (v & 0xFFFF) - 0x10000 : v & 0xFFFF;

  /// Util.arrayCopy: checks the bounds first, so nothing is copied when they are wrong.
  static void _copy(Uint8List src, int srcOff, Uint8List dest, int destOff, int length) {
    if (srcOff < 0 || destOff < 0 || length < 0 || srcOff + length > src.length || destOff + length > dest.length) {
      throw _OutOfBounds();
    }
    dest.setRange(destOff, destOff + length, Uint8List.fromList(src.sublist(srcOff, srcOff + length)));
  }

  static Uint8List _sw(int sw) => Uint8List.fromList([sw >> 8, sw & 0xFF]);
}

class _OutOfBounds implements Exception {}

PhoneSession newSession(String aids, {PhonePlatform platform = PhonePlatform.iphone, SimulatedCard? card}) =>
    PhoneSession(card ?? SimulatedCard(delay: Duration.zero), IosRules.parse(aids), _QuietLog(), platform: platform);

void main() {
  group('APDU', () {
    test('cases', () {
      expect(CommandApdu.parse(Hex.parse('00 A4 00 00')).$1!.apduCase, 1);
      expect(CommandApdu.parse(Hex.parse('00 B0 00 00 00')).$1!.ne, 256);
      expect(CommandApdu.parse(Hex.parse('00 D6 00 30 04')).$1!.ne, 4);
      final c3 = CommandApdu.parse(Hex.parse('00 A4 00 00 02 30 40')).$1!;
      expect(c3.apduCase, 3);
      expect(Hex.compact(c3.data), '3040');
      final c4 = CommandApdu.parse(PhoneSession.discoverySelect(Hex.parse(emg))).$1!;
      expect(c4.apduCase, 4);
      expect(c4.ne, 256);
    });

    test('invalid ones are refused', () {
      expect(CommandApdu.parse(Hex.parse('00 A4 00 00 03 30 40')).$1, isNull);
      expect(CommandApdu.parse(Hex.parse('00 B0 00 00 00 00')).$1, isNull);
    });

    test('iOS re-encoding', () {
      expect(Hex.of(CommandApdu.parse(Hex.parse('00 B0 00 00 00 01 00')).$1!.encode()), '00 B0 00 00 00');
      expect(Hex.of(CommandApdu.parse(Hex.parse('00 B0 00 00 00 00 00')).$1!.encode()), '00 B0 00 00 00 00 00');
    });
  });

  group('iOS rules', () {
    test('AID list entries', () {
      final r = IosRules.parse('45 4D 47 30 30 30 30 30 30 30, A000000003000000; F0 01 02 03 04 05\n0102, zz');
      expect(r.entries.length, 5);
      expect(r.entries[0].usable, isTrue);
      expect(r.entries[0].warning, isNotNull); // first digit 4
      expect(r.entries[1].usable, isFalse); // Visa RID
      expect(r.entries[2].warning, isNull);
      expect(r.entries[3].warning, isNotNull); // 2 bytes
      expect(r.entries[4].usable, isFalse); // bad hex
    });

    test('SELECT check', () {
      final rules = IosRules.parse(emg);
      CommandApdu c(String hex) => CommandApdu.parse(Hex.parse(hex)).$1!;
      expect(rules.checkSelect(c('00 A4 04 00 0A 45 4D 47 30 30 30 30 30 30 30')), isNull);
      expect(rules.checkSelect(c('00 A4 04 00 05 A0 00 00 09 99')), isNotNull);
      expect(rules.checkSelect(c('00 A4 04 00 0E 32 50 41 59 2E 53 59 53 2E 44 44 46 30 31 00')), isNotNull);
      expect(rules.checkSelect(c('00 A4 00 00 02 30 40')), isNull);
    });
  });

  group('iPhone session', () {
    test('tap, rules and the 60 s limit', () async {
      final s = newSession(emg);
      expect((await s.sendHex('80 08 00 00 0A', 'before')).status, SendStatus.noCard);
      expect(await s.tap(), isTrue);
      expect(s.initialSelectedAid, emg);
      expect((await s.sendHex('FF CA 00 00 00', 'uid')).status, SendStatus.readerCommand);
      expect((await s.sendHex('00 A4 00 00 05 30 40', 'bad')).status, SendStatus.invalid);
      final uid = await s.sendHex('80 08 00 00 0A', 'GET UID');
      expect(uid.ok, isTrue);
      expect(uid.response!.data.length, 10);
      s.ageForTest(61);
      expect((await s.sendHex('80 08 00 00 0A', 'late')).status, SendStatus.expired);
    });

    test('AID list order and blocked entries', () async {
      expect(await newSession('A0 00 00 09 99').tap(), isFalse);
      final first = newSession('A000000003000000, $emg');
      expect(await first.tap(), isTrue);
      expect(first.initialSelectedAid, emg);
      final isd = newSession('A000000151000000, $emg');
      expect(await isd.tap(), isTrue);
      expect(isd.initialSelectedAid, 'A000000151000000');
    });
  });

  group('Android session', () {
    test('finds the card without an AID list, sends any APDU as typed, no time limit', () async {
      final log = _QuietLog();
      final s = PhoneSession(SimulatedCard(delay: Duration.zero), IosRules.parse(''), log, platform: PhonePlatform.android);
      expect(await s.tap(), isTrue);
      expect(log.lines.any((l) => l.contains('00 A4 04 00 07 D2 76 00 00 85 01 01 00')), isTrue); // NDEF check
      final other = await s.sendHex('00 A4 04 00 05 A0 00 00 09 99', 'other AID');
      expect(other.ok, isTrue);
      expect(other.response!.sw, 0x6A86); // the applet answers it
      final payment = await s.sendHex('00 A4 04 00 0E 32 50 41 59 2E 53 59 53 2E 44 44 46 30 31 00', 'PPSE');
      expect(payment.ok, isTrue); // Android blocks no AID
      final raw = await s.sendHex('00 A4 00 00 05 30 40', 'bad Lc'); // sent as typed; the card decides
      expect(raw.ok, isTrue);
      expect(Hex.of(raw.sent), '00 A4 00 00 05 30 40');
      expect((await s.sendHex('FF CA 00 00 00', 'uid')).status, SendStatus.readerCommand);
      s.ageForTest(600);
      expect(s.expired, isFalse);
      expect((await s.sendHex('80 08 00 00 0A', 'still fine')).ok, isTrue);
    });
  });

  group('phone check', () {
    test('iPhone: YES with one warning (the first digit of the AID)', () async {
      final check = PhoneCheck(null);
      await check.run(newSession(emg));
      expect(check.yes, isTrue);
      expect(check.warnings, 1);
      final wrong = PhoneCheck(null);
      await wrong.run(newSession('F0 01 02 03 04 05'));
      expect(wrong.yes, isFalse);
    });

    test('Android: YES without warnings, and the AID list does not matter', () async {
      final check = PhoneCheck(null);
      await check.run(newSession('F0 01 02 03 04 05', platform: PhonePlatform.android));
      expect(check.yes, isTrue);
      expect(check.warnings, 0);
      expect(check.verdict, contains('Android'));
    });
  });

  group('card unit test', () {
    test('iPhone: 28 of 29 PASS, C30 blocked by iOS, 14 extra PASS, size 32768, data written back', () async {
      final test = CardTest(newSession(emg), _QuietLog());
      await test.run();
      final forty = test.rows.where((r) => r.group == CheckGroup.forty).toList();
      final extra = test.rows.where((r) => r.group == CheckGroup.extra).toList();
      expect(forty.length, 29);
      expect(extra.length, 14);
      expect(test.rows.length, CardTest.expectedRows);
      expect(test.failed, 0, reason: test.rows.where((r) => r.result == 'FAIL').map((r) => '${r.id} ${r.got}').join('\n'));
      expect(forty.where((r) => r.result == 'PASS').length, 28);
      expect(test.rows.firstWhere((r) => r.id == 'C30').result, 'BLOCKED');
      expect(extra.every((r) => r.result == 'PASS'), isTrue, reason: extra.map((r) => '${r.id} ${r.result} ${r.got}').join('\n'));
      expect(test.cardSize, 32768);
      expect(test.summary, contains('written back: yes'));
    });

    test('Android: all 29 and all 14 extra PASS', () async {
      final test = CardTest(newSession(emg, platform: PhonePlatform.android), _QuietLog());
      await test.run();
      expect(test.failed, 0, reason: test.rows.where((r) => r.result == 'FAIL').map((r) => '${r.id} ${r.got}').join('\n'));
      expect(test.rows.where((r) => r.group == CheckGroup.forty && r.result == 'PASS').length, 29);
      expect(test.rows.where((r) => r.group == CheckGroup.extra && r.result == 'PASS').length, 14);
      expect(test.cardSize, 32768);
    });

    test('the card data is the same after the test', () async {
      final card = SimulatedCard(delay: Duration.zero);
      final s = newSession(emg, card: card);
      await s.tap();
      await s.sendHex('00 A4 00 00 02 30 40', 'select');
      // put recognisable bytes where the test writes, then compare them afterwards
      await s.sendHex('00 D6 00 00 40 ${Hex.of(List<int>.generate(64, (i) => 0xA0 ^ i))}', 'prepare 0000');
      await s.sendHex('00 D6 01 00 FF ${Hex.of(List<int>.generate(255, (i) => 0x5A ^ i))}', 'prepare 0100');
      await s.sendHex('00 D6 7F C0 40 ${Hex.of(List<int>.generate(64, (i) => 0x33 ^ i))}', 'prepare 7FC0');
      Future<String> read(String apdu) async => Hex.of((await s.sendHex(apdu, 'read')).response!.data);
      final before = [await read('00 B0 00 00 40'), await read('00 B0 01 00 FF'), await read('00 B0 7F C0 40')];
      await CardTest(s, _QuietLog()).run();
      await s.tap();
      await s.sendHex('00 A4 00 00 02 30 40', 'select');
      final after = [await read('00 B0 00 00 40'), await read('00 B0 01 00 FF'), await read('00 B0 7F C0 40')];
      expect(after, before);
    });

    String failures(CardTest t) => t.rows.where((r) => r.result != 'PASS').map((r) => '${r.id} ${r.result} ${r.got}').join('\n');
    CheckRow row(CardTest t, String id) => t.rows.firstWhere((r) => r.id == id);

    test('old CAP on Android: all 47 rows run, the answers show the original applet, the data is the same after', () async {
      final card = _OriginalAppletCard();
      final mainBefore = Uint8List.fromList(card.main), extraBefore = card.extra[0];
      final test = CardTest(PhoneSession(card, IosRules.parse(emg), _QuietLog(), platform: PhonePlatform.android), _QuietLog());
      await test.run();
      expect(test.rows.length, CardTest.expectedRows);
      expect(test.rows.where((r) => r.notSent), isEmpty, reason: failures(test)); // every check reached the card
      expect(row(test, 'C01').result, 'FAIL');
      expect(row(test, 'C01').got, contains('6D 00'));
      expect(row(test, 'C02').result, 'PASS');
      expect(row(test, 'C12').result, 'PASS');
      expect(row(test, 'C13').got, startsWith('90 00')); // 80 A4 falls through to GET UID
      expect(row(test, 'C14').result, 'FAIL'); // the old hidden write at 0020
      expect(row(test, 'C15').got, contains('CA FE'));
      expect(row(test, 'X12').result, 'PASS');
      expect(test.cardSize, 32768);
      expect(test.originalApplet, isTrue);
      expect(test.summary, contains('ORIGINAL applet'));
      expect(test.summary, contains('written back: yes'));
      for (final id in ['C37', 'C38', 'C39', 'C40', 'X13', 'X14', 'C36', 'X15']) {
        expect(row(test, id).result, 'PASS', reason: '$id ${row(test, id).got}');
      }
      expect(card.main, mainBefore); // every byte, not only the saved areas
      expect(card.extra[0], extraBefore);
    });

    test('old CAP on an iPhone: never found, all 47 rows FAIL with the reason, only the discovery SELECTs are sent', () async {
      final card = _OriginalAppletCard();
      final test = CardTest(PhoneSession(card, IosRules.parse(emg), _QuietLog()), _QuietLog());
      await test.run();
      expect(test.rows.length, CardTest.expectedRows);
      expect(test.rows.where((r) => r.result != 'FAIL'), isEmpty);
      expect(row(test, 'S1').got, contains('no AID of the list answered 90 00'));
      expect(row(test, 'C06').got, startsWith('not sent: the iPhone did not find the card'));
      expect(row(test, 'C37').got, startsWith('not sent'));
      expect(test.rows.where((r) => r.notSent).length, CardTest.expectedRows - 2); // all but the two taps
      expect(card.sent.length, 2);
      expect(card.sent.every((a) => a.startsWith('00 A4 04 00 0A 45 4D 47')), isTrue);
      expect(test.cardSize, isNull);
      expect(test.summary, contains('never found the card'));
    });

    test('old CAP on an iPhone whose AID list has the old AID: found, C01 blocked, every other check runs', () async {
      final card = _OriginalAppletCard();
      final mainBefore = Uint8List.fromList(card.main);
      final test = CardTest(PhoneSession(card, IosRules.parse('67 61 73 65 6C 65 63 74'), _QuietLog()), _QuietLog());
      await test.run();
      expect(test.rows.length, CardTest.expectedRows);
      expect(row(test, 'S1').result, 'PASS');
      expect(row(test, 'C01').got, startsWith('not sent')); // iOS blocks SELECT of an AID outside the list
      expect(row(test, 'C30').result, 'BLOCKED');
      expect(row(test, 'C02').result, 'PASS');
      expect(row(test, 'C13').result, 'FAIL');
      expect(row(test, 'X12').result, 'PASS');
      for (final id in ['C37', 'C38', 'C39', 'C40', 'X13', 'X14', 'C36', 'X15']) {
        expect(row(test, id).result, 'PASS', reason: '$id ${row(test, id).got}');
      }
      // only the 3 SELECTs of the EMG AID did not reach the card (C30 is the expected iOS block)
      expect(test.rows.where((r) => r.notSent && r.result == 'FAIL').map((r) => r.id), ['C01', 'C31', 'C33']);
      expect(test.summary, contains('ORIGINAL applet'));
      expect(card.main, mainBefore);
    });

    test('Read card on an iPhone whose AID list has the old AID: the warning says iOS blocked the SELECT', () async {
      final r = await CardReader(PhoneSession(_OriginalAppletCard(), IosRules.parse('67 61 73 65 6C 65 63 74'), _QuietLog()), _QuietLog()).run();
      expect(r.ok, isTrue, reason: r.message);
      expect(r.bytesRead, 32768);
      expect(r.warnings.first, contains('iOS blocks it'));
      expect(r.warnings.first, contains('initialSelectedAID 676173656C656374'));
    });

    test('the bytes cannot be saved: no command that writes is sent, the other checks still run', () async {
      final card = _ChangedCard((apdu) => apdu == '00 B0 00 00 40' ? Uint8List.fromList([0x6F, 0x00]) : null);
      final test = CardTest(PhoneSession(card, IosRules.parse(emg), _QuietLog(), platform: PhonePlatform.android), _QuietLog());
      await test.run();
      expect(test.rows.length, CardTest.expectedRows);
      expect(card.sent.where((a) => a.startsWith('00 D6') || a.startsWith('84 D6') || a.startsWith('00 08')), isEmpty);
      expect(row(test, 'C06').got, startsWith('not run: could not save 0000-003F'));
      expect(row(test, 'C37').got, startsWith('not run: nothing was written'));
      expect(row(test, 'C04').result, 'PASS');
      expect(row(test, 'C05').result, 'PASS');
      expect(row(test, 'X12').result, 'PASS');
      expect(row(test, 'C36').result, 'PASS');
      expect(test.summary, contains('written back: nothing was written'));
    });

    test('one command fails on the way: the rest is listed, the bytes are still written back, the error comes at the end', () async {
      var failedOnce = false;
      final card = _ChangedCard((apdu) {
        if (apdu == '80 A4 00 00 02 30 40' && !failedOnce) {
          failedOnce = true;
          throw CardException('Transmission error.');
        }
        return null;
      });
      await card.inner.connect();
      Future<List<String>> areas() async {
        card.inner.transmitNow(Hex.parse('00 A4 00 00 02 30 40'));
        String read(String apdu) => Hex.of(card.inner.transmitNow(Hex.parse(apdu)));
        return [read('00 B0 00 00 40'), read('00 B0 01 00 FF'), read('00 B0 7F C0 40')];
      }

      final before = await areas();
      final test = CardTest(PhoneSession(card, IosRules.parse(emg), _QuietLog()), _QuietLog());
      await expectLater(test.run(), throwsA(isA<CardException>()));
      expect(test.rows.length, CardTest.expectedRows);
      expect(row(test, 'C12').result, 'PASS');
      expect(row(test, 'C13').got, 'not sent: Transmission error.');
      expect(row(test, 'X11').got, 'not sent: Transmission error.');
      for (final id in ['C37', 'C38', 'C39', 'C40', 'X13', 'X14']) {
        expect(row(test, id).result, 'PASS', reason: '$id ${row(test, id).got}');
      }
      expect(test.summary, contains('written back: yes'));
      expect(row(test, 'S2').result, 'PASS'); // tap 2 still runs
      expect(row(test, 'C36').result, 'PASS');
      expect(await areas(), before);
    });

    test('the card is taken away: every row is still listed and the saved bytes go to the log', () async {
      late _ChangedCard card;
      card = _ChangedCard((apdu) {
        if (apdu == '00 B0 40 00 00') {
          card.removed = true; // gone in the middle of C12
          throw CardException('The card was removed.');
        }
        return null;
      });
      final log = _QuietLog();
      final test = CardTest(PhoneSession(card, IosRules.parse(emg), log, platform: PhonePlatform.android), log);
      await expectLater(test.run(), throwsA(isA<CardException>()));
      expect(test.rows.length, CardTest.expectedRows);
      expect(row(test, 'C12').got, '16384 bytes, then not sent: The card was removed.');
      expect(row(test, 'C37').result, 'FAIL');
      expect(row(test, 'S2').got, contains('not found'));
      expect(row(test, 'X15').got, startsWith('not sent'));
      expect(test.summary, contains('written back: NO'));
      expect(log.lines.any((l) => l.contains('To do it by hand')), isTrue);
    });
  });

  group('error map', () {
    int swOf(String text) => int.parse(text.substring(0, 5).replaceAll(' ', ''), radix: 16);

    test("every example of the map gets its check, and the original applet's answer its F-number", () {
      for (final c in errorMapChecks) {
        final cmd = Hex.parse(c.example);
        final now = explainAnswer(cmd, swOf(c.now));
        if (c.isOk) {
          expect(now.kind, AnswerKind.success, reason: '${c.id}: ${now.text}');
        } else {
          expect(now.kind, AnswerKind.appletError, reason: '${c.id}: ${now.text}');
          expect(now.check!.id, c.id, reason: now.text);
        }
        if (c.finding.isNotEmpty) {
          final old = explainAnswer(cmd, swOf(c.original));
          expect(old.kind, AnswerKind.originalApplet, reason: '${c.id}: ${old.text}');
          expect(old.finding, c.finding, reason: '${c.id}: ${old.text}');
        }
      }
    });

    test('answers outside the map, SELECT by AID, and the meter advice', () {
      final notSelected = explainAnswer(Hex.parse('00 B0 00 00 10'), 0x6986);
      expect(notSelected.tag, 'READ 2');
      expect(notSelected.detail, contains('Send 00 A4 00 00 02 30 40'));
      expect(explainAnswer(Hex.parse('00 B0 7F F8 10'), 0x6C08).detail, contains('Only 8 bytes are left after 7FF8'));
      expect(explainAnswer(Hex.parse('00 B0 7F F8 10'), 0x6C10).kind, AnswerKind.unexpected); // wrong xx
      expect(explainAnswer(Hex.parse('00 B0 00 00 10'), 0x6F00).kind, AnswerKind.unexpected); // not even the old applet
      expect(explainAnswer(Hex.parse('00 A4 04 00 0A $emg'), 0x9000).kind, AnswerKind.success);
      final oldSelect = explainAnswer(Hex.parse('00 A4 04 00 0A $emg'), 0x6D00);
      expect(oldSelect.tag, 'OLD F5');
      expect(oldSelect.title, contains('not on the card'));
      expect(explainAnswer(Hex.parse('00 A4 04 00 05 A0 00 00 09 99'), 0x6A86).tag, 'SELECT 2');
      expect(explainAnswer(Hex.parse('00 A4 04 00 08 A0 00 00 01 51 00 00 00'), 0x9000).kind, AnswerKind.success); // the ISD
    });

    test('the full test: every answer of the applet is in the map; on the old CAP every failure is an original-applet answer', () async {
      final sim = CardTest(newSession(emg, platform: PhonePlatform.android), _QuietLog());
      await sim.run();
      final simOdd = sim.rows.where((r) => r.answer != null && r.answer!.kind != AnswerKind.success && r.answer!.kind != AnswerKind.appletError);
      expect(simOdd, isEmpty, reason: simOdd.map((r) => '${r.id} ${r.answer!.text}').join('\n'));
      expect(sim.rows.firstWhere((r) => r.id == 'C29').answer!.tag, 'READ 2');

      final old = CardTest(PhoneSession(_OriginalAppletCard(), IosRules.parse(emg), _QuietLog(), platform: PhonePlatform.android), _QuietLog());
      await old.run();
      final failed = old.rows.where((r) => r.result != 'PASS' && r.answer != null).toList();
      expect(failed.length, 13);
      final notOld = failed.where((r) => r.answer!.kind != AnswerKind.originalApplet).map((r) => '${r.id} ${r.answer!.text}').toList();
      expect(notOld, ['C15 ${failed.firstWhere((r) => r.id == 'C15').answer!.text}']); // C15: right SW, data written by C14
      String tag(String id) => old.rows.firstWhere((r) => r.id == id).answer!.tag;
      expect(tag('C15'), 'DATA');
      expect(tag('C01'), 'OLD F5');
      expect(tag('C13'), 'OLD F1');
      expect(tag('C14'), 'OLD F1');
      expect(old.summary, contains('Error map: 12 of the answers that did not pass are what the ORIGINAL applet sends'));
    });
  });

  test('HTML report has the results, the size and the setup', () async {
    final s = newSession(emg);
    final check = PhoneCheck(null);
    await check.run(s);
    final test = CardTest(s, _QuietLog());
    await test.run();
    final html = buildHtmlReport(ReportInput(
      generatedAt: DateTime(2026, 10, 2, 12),
      reader: 'Simulator',
      platform: 'iPhone',
      aidList: emg,
      atr: '3B 89 80 01 00 31 C1 73 C8 40 00 00 90 93',
      checkPlatform: 'iPhone',
      checkVerdict: check.verdict,
      checkYes: check.yes,
      checkRows: check.rows,
      testPlatform: 'iPhone',
      testSummary: test.summary,
      testRows: test.rows,
      cardSize: test.cardSize,
      cardSizeStop: test.cardSizeStop,
      log: const ['<script>alert(1)</script>'],
    ));
    expect(html, startsWith('<!doctype html>'));
    expect(html, contains('Card test report'));
    expect(html, contains('32768 bytes'));
    expect(html, contains('X12'));
    expect(html, contains('C40'));
    expect(html, contains('Card checks'));
    expect(html, contains('Type (error map)'));
    expect(html, contains('class="tag t-appletError"')); // C17 answers 6A 82: SELECT 4
    expect(html, isNot(contains('<script>alert(1)</script>'))); // the log is escaped
    expect(html, contains('&lt;script&gt;'));
  });

  test('every page the app writes is dark, and still readable when printed', () async {
    final s = newSession(emg);
    final test = CardTest(s, _QuietLog());
    await test.run();
    final read = await CardReader(newSession(emg), _QuietLog()).run();
    final pages = {
      'test report': buildHtmlReport(ReportInput(
        generatedAt: DateTime(2026, 10, 2),
        reader: 'Simulator',
        platform: 'iPhone',
        aidList: emg,
        testRows: test.rows,
        testSummary: test.summary,
      )),
      'data report': buildDataReport(read, reader: 'Simulator'),
      'guide': buildGuideHtml(generatedAt: DateTime(2026, 10, 2)),
    };
    for (final page in pages.entries) {
      final html = page.value;
      expect(html, contains('color-scheme:dark'), reason: '${page.key} should be dark');
      expect(html, contains('--bg:#0a0f1e'), reason: '${page.key} should use the dark background');
      // nothing may put it back to a light page depending on the browser's setting
      expect(html, isNot(contains('prefers-color-scheme')), reason: '${page.key} must not follow the browser theme');
      // a printout swaps to a light palette, or pale text would land on white paper
      expect(html, contains('@media print'), reason: '${page.key} should stay readable on paper');
      expect(html, contains('color-scheme:light'), reason: '${page.key} should print light');
    }
  });

  test('the guide lists what the app can do before any of the detail', () {
    final html = buildGuideHtml(generatedAt: DateTime(2026, 10, 2));
    expect(guideFeatures.length, greaterThanOrEqualTo(8));
    expect(html.indexOf('What it can do'), lessThan(html.indexOf('On this page')));
    for (final f in guideFeatures) {
      // the page escapes its text, so a name with & in it ("Read & write card") is there as &amp;
      expect(html, contains(f.name.replaceAll('&', '&amp;')), reason: '${f.name} should be in the summary');
    }
    expect(guideFeatures.map((f) => f.name), contains('iPhone (iOS) check'));
    expect(guideFeatures.map((f) => f.name), contains('Android check'));
    // every icon the summary and the sections ask for has a real icon behind it
    for (final name in [...guideFeatures.map((f) => f.icon), ...guideSections.map((s) => s.icon)]) {
      expect(HomePage.iconFor(name), isNot(Icons.article_outlined), reason: 'no icon for "$name"');
    }
  });

  test('the console explains a command while it is typed', () {
    final read = describeCommand(Hex.parse('00 B0 7F 00 00'));
    expect(read, contains('READ BINARY'));
    expect(read, contains('offset 7F00'));
    expect(read, contains('Le 00 (256 bytes)'));
    expect(describeCommand(Hex.parse('00 A4 04 00 0A $emg')), contains('SELECT by AID'));
    expect(describeCommand(Hex.parse('00 D6 00 20 02 11 22')), contains('writes to the card'));
    expect(describeCommand(Hex.parse('00 A4 00 00 05 30 40')), contains('Not a valid'));
  });

  group('read card', () {
    Uint8List sw(int a, int b) => Uint8List.fromList([a, b]);
    PhoneSession changed(_ChangedCard card, {PhonePlatform platform = PhonePlatform.android}) =>
        PhoneSession(card, IosRules.parse(emg), _QuietLog(), platform: platform);

    for (final platform in PhonePlatform.values) {
      test('${platform.short}: the whole 32 KB is read, OK', () async {
        final s = newSession(emg, platform: platform);
        final r = await CardReader(s, _QuietLog()).run();
        expect(r.ok, isTrue, reason: r.message);
        expect(r.bytesRead, r.expected);
        expect(r.expected, CardReadResult.defaultSize);
        expect(r.warnings, isEmpty);
        expect(r.message, startsWith('OK'));
        expect(Hex.of(r.image.sublist(0, 10)), Hex.of(r.cardId)); // the simulator keeps its card ID at 0000
        expect(String.fromCharCodes(r.image.sublist(0x10, 0x10 + 14)), 'EMG METER CARD');
        expect(r.image[0x7FFF], 0x5A); // the last byte, from extraStorageBuffer
        final kinds = r.blockKinds;
        expect(kinds.length, 128);
        expect(kinds[0x00], 'data');
        expect(kinds[0x10], 'data');
        expect(kinds[0x20], 'FF');
        expect(kinds[0x30], '00');
        expect(r.missing, isEmpty);
      });
    }

    test('the last block cannot be read: 32512 bytes, the data is kept, then EXCEPTION', () async {
      final r = await CardReader(changed(_ChangedCard((apdu) => apdu.startsWith('00 B0 7F') ? sw(0x6F, 0x00) : null)), _QuietLog()).run();
      expect(r.ok, isFalse);
      expect(r.bytesRead, 32512);
      expect(r.blocks[0x7E].complete, isTrue);
      expect(r.blocks[0x7F].bytes, 0);
      expect(String.fromCharCodes(r.image.sublist(0x10, 0x10 + 14)), 'EMG METER CARD'); // what was read is there
      expect(r.message, contains('EXCEPTION'));
      expect(r.message, contains('only 32512'));
      expect(r.missing.length, 1);
      expect(r.missing.first.$1, 0x7F00);
      expect(r.missing.first.$2, 0x7FFF);
      expect(r.missing.first.$3, contains('6F 00'));
      expect(r.blockKinds[0x7F], 'missing');
    });

    test('a block in the middle fails: the reading goes on with the next blocks', () async {
      final r = await CardReader(changed(_ChangedCard((apdu) => apdu.startsWith('00 B0 40') ? sw(0x6F, 0x00) : null)), _QuietLog()).run();
      expect(r.ok, isFalse);
      expect(r.bytesRead, 32512);
      expect(r.blocks[0x40].bytes, 0);
      expect(r.blocks[0x41].complete, isTrue);
      expect(r.blocks[0x7F].complete, isTrue);
      expect(r.image[0x7FFF], 0x5A); // read after the failing block
      expect(r.missing.single.$1, 0x4000);
    });

    test('Le 00 fails but 16-byte parts work: every byte is read, OK with a warning', () async {
      final r = await CardReader(changed(_ChangedCard((apdu) => apdu == '00 B0 7F 00 00' ? sw(0x6F, 0x00) : null)), _QuietLog()).run();
      expect(r.ok, isTrue, reason: r.message);
      expect(r.bytesRead, 32768);
      expect(r.image[0x7FFF], 0x5A);
      expect(r.warnings.single, contains('16 bytes at a time'));
      expect(r.message, contains('with 1 warning'));
    });

    test('the file ends inside a block (6C xx): the bytes before the end are kept', () async {
      final r = await CardReader(
          changed(_ChangedCard((apdu) => switch (apdu) {
                '00 B0 7F 00 00' => sw(0x6C, 0x80), // only 128 bytes left
                '00 B0 7F 80 80' => sw(0x6B, 0x00), // nothing after 7F7F
                _ => null,
              })),
          _QuietLog()).run();
      expect(r.ok, isFalse);
      expect(r.bytesRead, 32640);
      expect(r.blocks[0x7F].bytes, 128);
      expect(r.blockKinds[0x7F], 'partial');
      expect(r.missing.single.$1, 0x7F80);
      expect(r.missing.single.$3, contains('6B 00'));
    });

    test('the card is taken away in the middle: what was read is kept, no crash', () async {
      late _ChangedCard card;
      var reads = 0;
      card = _ChangedCard((apdu) {
        if (apdu.startsWith('00 B0') && ++reads > 48) {
          card.removed = true; // gone after 48 blocks
          throw CardException('The card was removed.');
        }
        return null;
      });
      final r = await CardReader(changed(card), _QuietLog()).run();
      expect(r.ok, isFalse);
      expect(r.bytesRead, 48 * 256);
      expect(r.blocks[47].complete, isTrue);
      expect(r.blocks[48].bytes, 0);
      expect(r.warnings.any((w) => w.contains('stopped answering')), isTrue);
      expect(r.message, contains('only 12288'));
    });

    test('old CAP: SELECT by AID answers 6D 00; Android still reads all 32 KB through the default applet', () async {
      final card = _ChangedCard((apdu) => apdu.startsWith('00 A4 04 00 0A 45 4D') ? sw(0x6D, 0x00) : null);
      final r = await CardReader(changed(card), _QuietLog()).run();
      expect(r.ok, isTrue, reason: r.message);
      expect(r.bytesRead, 32768);
      expect(r.warnings.first, contains('6D 00'));
      expect(r.message, contains('warning'));
    });

    test('old CAP on an iPhone: the iPhone never finds the card, EXCEPTION', () async {
      final card = _ChangedCard((apdu) => apdu.startsWith('00 A4 04 00 0A 45 4D') ? sw(0x6D, 0x00) : null);
      final r = await CardReader(changed(card, platform: PhonePlatform.iphone), _QuietLog()).run();
      expect(r.ok, isFalse);
      expect(r.bytesRead, 0);
      expect(r.error, contains('did not find the card'));
      expect(r.message, startsWith('EXCEPTION'));
    });

    test('a card with data past 7FFF: EXCEPTION (more)', () async {
      final r = await CardReader(
          changed(_ChangedCard((apdu) => apdu == '00 B0 7F FF 02' ? Uint8List.fromList([0x5A, 0x77, 0x90, 0x00]) : null)),
          _QuietLog()).run();
      expect(r.ok, isFalse);
      expect(r.moreThanExpected, isTrue);
      expect(r.bytesRead, 32768);
      expect(r.message, contains('MORE than 32768'));
    });

    test('the data report shows the data, the parts not read (--), the warnings and the block map', () async {
      final ok = await CardReader(newSession(emg), _QuietLog()).run();
      final html = buildDataReport(ok, reader: 'Simulator', atr: '3B 89 80 01', uid: '04 11 22 33 44 55 66');
      expect(html, startsWith('<!doctype html>'));
      expect(html, contains('OK: the whole card was read'));
      expect(html, contains('id="b00"'));
      expect(html, contains('id="b7F"'));
      expect(html, contains('href="#b20"'));
      expect(html, contains('EMG METER CARD'));
      expect(html, isNot(contains('<u>--</u>')));

      final short = await CardReader(
          changed(_ChangedCard((apdu) => switch (apdu) {
                '00 A4 04 00 0A 45 4D 47 30 30 30 30 30 30 30' => sw(0x6D, 0x00),
                _ => apdu.startsWith('00 B0 7F') ? sw(0x6F, 0x00) : null,
              })),
          _QuietLog()).run();
      final html2 = buildDataReport(short, reader: 'test');
      expect(html2, contains('EXCEPTION'));
      expect(html2, contains('Not read'));
      expect(html2, contains('7F00-7FFF'));
      expect(html2, contains('<u>--</u>'));
      expect(html2, contains('class="cell kmissing"'));
      expect(html2, contains('Warnings'));
      expect(html2, contains('6D 00'));
      expect(html2, contains('EMG METER CARD')); // the data that was read is in the report

      // ASCII in the data is escaped
      final image = Uint8List(32768)..setAll(0, [0x3C, 0x62, 0x3E]);
      final blocks = List<BlockRead>.generate(128, BlockRead.new);
      blocks[0].bytes = 256;
      final odd = CardReadResult(
        image: image,
        blocks: blocks,
        platform: PhonePlatform.android,
        time: DateTime(2026, 10, 2),
        seconds: 0.1,
        commands: 3,
      );
      final html3 = buildDataReport(odd, reader: 'test');
      expect(html3, contains('&lt;b&gt;'));
      expect(html3, isNot(contains('<b>')));
    });
  });
}
