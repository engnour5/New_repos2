// ignore_for_file: avoid_print
// READ-ONLY dump of the applet's command log (80 F2 status + 80 F3 read). Does NOT reset (80 F0) or freeze, so it shows
// exactly what is logged now. Run with the app DISCONNECTED (reader is exclusive):
//   flutter test tool\logger_dump.dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/pcsc.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/hex.dart';

void main() {
  test('DUMP the applet command log', () async {
    final readers = await PcscChannel.listReaders();
    final name = readers.firstWhere((r) => r.toLowerCase().contains('contactless'), orElse: () => readers.first);
    print('reader: $name');
    final channel = PcscChannel(name);
    await channel.connect();
    try {
      Future<ResponseApdu> send(String hex) async => ResponseApdu.fromRaw(await channel.transmit(Hex.parse(hex)));

      try { await channel.fieldReset(); } catch (_) {}
      var sel = await send('00 A4 04 00 0A 45 4D 47 30 30 30 30 30 30 30');
      if (sel.sw != 0x9000) sel = await send('00 A4 04 00 09 45 4D 47 30 30 30 30 30 30');
      print('SELECT applet -> ${sel.swText}');

      final st = await send('80 F2 00 00 04');
      print('80 F2 status -> ${st.swText}  ${st.data.isEmpty ? '' : Hex.of(st.data)}');
      if (st.data.length < 4 || st.sw != 0x9000) { print('*** no status (is the logger in the card? 80 F0 must give 90 00) ***'); return; }
      final count = (st.data[0] << 8) | st.data[1];
      final ptr = (st.data[2] << 8) | st.data[3];
      print('logCount=$count   logPtr=$ptr bytes\n');
      if (ptr == 0) { print('*** the log is EMPTY (nothing was logged since the last reset) ***'); return; }

      // read logPtr bytes in 256-byte chunks
      final all = <int>[];
      for (var off = 0; off < ptr; off += 256) {
        final r = await send('80 F3 ${h2(off >> 8)} ${h2(off & 0xff)} 00');
        if (r.sw != 0x9000) { print('80 F3 at $off -> ${r.swText}'); break; }
        all.addAll(r.data);
      }
      final d = Uint8List.fromList(all.take(ptr).toList());
      print('=== $count records ===');
      for (var i = 0; i + 16 <= d.length; i += 16) {
        final r = d.sublist(i, i + 16);
        final sw = ((r[14] & 0xff) << 8) | (r[15] & 0xff);
        print('  CLA ${h2(r[0])} INS ${h2(r[1])} P1 ${h2(r[2])} P2 ${h2(r[3])} P3 ${h2(r[4])}'
            '  data ${Hex.of(Uint8List.fromList(r.sublist(5, 14)))}  SW ${sw.toRadixString(16).padLeft(4, '0').toUpperCase()}');
      }
    } finally {
      await channel.disconnect();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
