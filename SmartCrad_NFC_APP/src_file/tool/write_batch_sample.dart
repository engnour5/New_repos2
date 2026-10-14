// ignore_for_file: avoid_print  -- a console script: printing is how it reports.
// Writes a sample Auto load report from a run on the simulated card, to check how the page looks with no reader.
//   flutter test tool\write_batch_sample.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/simulated_card.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/batch_report.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/gp/batch_burn.dart';
import 'package:iphone_nfc_tester/gp/cap_file.dart';
import 'package:iphone_nfc_tester/gp/gp_keys.dart';

class _Quiet implements Logger {
  @override
  void section(String t) {}
  @override
  void info(String t) {}
  @override
  void warn(String t) {}
  @override
  void exchange(String l, Uint8List s, ResponseApdu r, double ms) {}
  @override
  void blocked(String l, Uint8List t, String r) {}
}

void main() {
  test('write a sample auto_load report', () async {
    final capPath = [
      r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\gas_electrometer_javaApplet\Versions\electrical_electrometer_2026-10-01.cap',
      r'D:\Applet_Card_G2\gas_electrometer_javaApplet\bin\Debug\electrical_electrometer\javacard\electrical_electrometer.cap',
    ].where((p) => File(p).existsSync()).firstOrNull;
    if (capPath == null) {
      markTestSkipped('No CAP file on this PC.');
      return;
    }
    final cap = await CapFile.read(capPath);
    late final BatchBurn batch;
    batch = BatchBurn(
      channel: SimulatedCard(delay: Duration.zero),
      log: _Quiet(),
      keys: GpKeys.defaultTestKey().keys,
      cap: cap,
      instanceAid: cap.appletAids.first,
      moduleAid: cap.appletAids.first,
      poll: Duration.zero,
      onChanged: () {
        if (batch.done >= 6) batch.stop();
      },
    );
    await batch.run();

    final html = buildBatchReport(BatchReportInput(
      generatedAt: DateTime.now(),
      batch: batch,
      reader: 'Identive CLOUD 4700 F Contactless Reader 0',
      capName: cap.name,
      packageAid: Hex.of(cap.packageAid),
      instanceAid: Hex.of(cap.appletAids.first),
      defaultSelected: true,
      deleteFirst: true,
      startedAt: DateTime.now().subtract(const Duration(minutes: 3)),
      simulated: true,
    ));
    final file = File('${Directory.current.parent.path}\\Outputs_Files\\auto_load_sample.html');
    await file.parent.create(recursive: true);
    await file.writeAsString(html);
    print('wrote ${file.path}  (${html.length} characters, ${batch.ok} cards)');
    expect(html, contains('Auto load report'));
  });
}
