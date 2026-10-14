// ignore_for_file: avoid_print
// ARM the applet log: SELECT applet + 80 F0 (clear + enable), then confirm it is 0. Leaves logging ON in the card, so
// you can move the card straight to the phone and the phone's commands get logged. Run with the app DISCONNECTED:
//   flutter test tool\logger_arm.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/pcsc.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/hex.dart';

void main() {
  test('ARM the applet log', () async {
    final readers = await PcscChannel.listReaders();
    final name = readers.firstWhere((r) => r.toLowerCase().contains('contactless'), orElse: () => readers.first);
    final channel = PcscChannel(name);
    await channel.connect();
    try {
      Future<ResponseApdu> send(String label, String hex) async {
        final r = ResponseApdu.fromRaw(await channel.transmit(Hex.parse(hex)));
        print('  $label | << ${r.swText}${r.data.isEmpty ? '' : '  ${Hex.of(r.data)}'}');
        return r;
      }

      try { await channel.fieldReset(); } catch (_) {}
      var sel = await send('SELECT applet', '00 A4 04 00 0A 45 4D 47 30 30 30 30 30 30 30');
      if (sel.sw != 0x9000) sel = await send('SELECT applet (9)', '00 A4 04 00 09 45 4D 47 30 30 30 30 30 30');
      final f0 = await send('80 F0 ARM    ', '80 F0 00 00');
      await send('80 F2 status ', '80 F2 00 00 04');
      print(f0.sw == 0x9000
          ? '\n  *** ARMED. Remove the card and put it on the phone, run ePower, then bring it back. ***'
          : '\n  *** 80 F0 = ${f0.swText} (no logger?) ***');
    } finally {
      await channel.disconnect();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
