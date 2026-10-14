// ignore_for_file: avoid_print
// Headless diagnostic for the applet command-logger. READ-ONLY except it enables/reads the log (80 Fx) and does a
// harmless SELECT EF + GET UID. Run with the app DISCONNECTED (the reader is exclusive):
//   flutter test tool\logger_diag.dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/pcsc.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/hex.dart';

void main() {
  test('LOGGER DIAGNOSTIC on the real card', () async {
    final readers = await PcscChannel.listReaders();
    print('readers: $readers');
    expect(readers, isNotEmpty, reason: 'no PC/SC reader found');
    final name = readers.firstWhere((r) => r.toLowerCase().contains('contactless'), orElse: () => readers.first);
    print('using reader: $name');
    final channel = PcscChannel(name);
    await channel.connect();
    try {
      Future<ResponseApdu> send(String label, String hex) async {
        final r = ResponseApdu.fromRaw(await channel.transmit(Hex.parse(hex)));
        print('  $label | >> $hex | << ${r.swText}${r.data.isEmpty ? '' : '  (${r.data.length} data: ${Hex.of(r.data)})'}');
        return r;
      }

      try {
        await channel.fieldReset();
      } catch (_) {}

      // select the applet; the AID is EMG0000000 (10 bytes). Try 10 then 9 bytes.
      var sel = await send('SELECT applet AID (10)', '00 A4 04 00 0A 45 4D 47 30 30 30 30 30 30 30');
      if (sel.sw != 0x9000) sel = await send('SELECT applet AID (9) ', '00 A4 04 00 09 45 4D 47 30 30 30 30 30 30');
      print(sel.sw == 0x9000 ? '  -> applet selected' : '  -> *** applet NOT selected (${sel.swText}) ***');

      final f0 = await send('80 F0 enable+reset     ', '80 F0 00 00');
      if (f0.sw != 0x9000) {
        print('\n  *** 80 F0 returned ${f0.swText}, not 90 00 -> the burned CAP has NO logger (old build). Rebuild + reburn. ***');
      }

      await send('80 F2 status (expect 0)', '80 F2 00 00 04');
      await send('80 08 GET UID          ', '80 08 00 00 0A');
      await send('00 A4 SELECT EF 3040    ', '00 A4 00 00 02 30 40');
      final st = await send('80 F2 status (expect>0)', '80 F2 00 00 04');
      if (st.data.length >= 4) {
        final count = (st.data[0] << 8) | st.data[1];
        final ptr = (st.data[2] << 8) | st.data[3];
        print('  -> logCount=$count, logPtr=$ptr bytes');
        if (count == 0) print('  *** logCount is still 0 -> logging is not recording ***');
      }

      final log = await send('80 F3 read 64 bytes     ', '80 F3 00 00 40');
      final d = log.data;
      print('\n  === decoded log (${d.length} bytes, 16 per record) ===');
      for (var i = 0; i + 16 <= d.length; i += 16) {
        final r = d.sublist(i, i + 16);
        final sw = ((r[14] & 0xff) << 8) | (r[15] & 0xff);
        print('    CLA ${h2(r[0])} INS ${h2(r[1])} P1 ${h2(r[2])} P2 ${h2(r[3])} P3 ${h2(r[4])}'
            '  data ${Hex.of(Uint8List.fromList(r.sublist(5, 14)))}  SW ${sw.toRadixString(16).padLeft(4, '0').toUpperCase()}');
      }
    } finally {
      await channel.disconnect();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
