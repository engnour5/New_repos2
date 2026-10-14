// ignore_for_file: avoid_print  -- a console script: printing is how it reports.
// Writes one of each page the app generates, from the simulated card, so the look can be checked without a reader.
//   flutter test tool\write_sample_html.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/simulated_card.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/card_reader.dart';
import 'package:iphone_nfc_tester/core/card_test.dart';
import 'package:iphone_nfc_tester/core/data_report.dart';
import 'package:iphone_nfc_tester/core/guide_html.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/ios_rules.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/core/phone_check.dart';
import 'package:iphone_nfc_tester/core/report.dart';
import 'package:iphone_nfc_tester/core/session.dart';

const outDir = r'C:\Users\NOUR~1.ASH\AppData\Local\Temp\claude\D--Applet-Card-G2-gas-electrometer-javaApplet-src\dc8af9b5-221c-40b3-833f-959a39515ea4\scratchpad';

class _Quiet implements Logger {
  final lines = <String>[];
  @override
  void section(String t) => lines.add('=== $t');
  @override
  void info(String t) => lines.add(t);
  @override
  void warn(String t) => lines.add('! $t');
  @override
  void exchange(String l, sent, ResponseApdu r, double ms) => lines.add('>> ${Hex.of(sent)} << ${r.swText}');
  @override
  void blocked(String l, typed, String why) => lines.add('NOT SENT');
}

void main() {
  test('write one of each page', () async {
    PhoneSession session() =>
        PhoneSession(SimulatedCard(delay: Duration.zero), IosRules.parse('454D4730303030303030'), _Quiet());

    final log = _Quiet();
    final check = PhoneCheck(null);
    await check.run(session());
    final test = CardTest(session(), log);
    await test.run();
    final read = await CardReader(session(), _Quiet()).run();

    final pages = {
      'sample_report.html': buildHtmlReport(ReportInput(
        generatedAt: DateTime.now(),
        reader: 'Simulated card',
        platform: 'iPhone',
        aidList: '454D4730303030303030',
        atr: '3B 89 80 01 00 31 C1 73 C8 40 00 00 90 93',
        checkPlatform: 'iPhone',
        checkTime: DateTime.now(),
        checkVerdict: check.verdict,
        checkYes: check.yes,
        checkRows: check.rows,
        testPlatform: 'iPhone',
        testTime: DateTime.now(),
        testSummary: test.summary,
        testRows: test.rows,
        cardSize: test.cardSize,
        cardSizeStop: test.cardSizeStop,
        log: log.lines.take(40).toList(),
      )),
      'sample_data.html': buildDataReport(read, reader: 'Simulated card', atr: '3B 89 80 01', uid: '04 11 22 33'),
      'sample_guide.html': buildGuideHtml(),
    };
    for (final p in pages.entries) {
      File('$outDir\\${p.key}').writeAsStringSync(p.value);
      print('wrote ${p.key}  (${p.value.length} characters)');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
