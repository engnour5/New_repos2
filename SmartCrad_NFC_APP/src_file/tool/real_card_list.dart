// ignore_for_file: avoid_print  -- a console script: printing is how it reports what the card holds.
// READ-ONLY. It opens a secure channel and lists everything on the card with its privileges, and nothing else.
//   flutter test tool\real_card_list.dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/pcsc.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/gp/card_manager.dart';
import 'package:iphone_nfc_tester/gp/gp_keys.dart';

class _QuietLog implements Logger {
  @override
  void section(String text) {}
  @override
  void info(String text) {}
  @override
  void warn(String text) => print('  ! $text');
  @override
  void exchange(String label, Uint8List sent, ResponseApdu response, double ms) {}
  @override
  void blocked(String label, Uint8List typed, String reason) {}
}

void main() {
  test('REAL CARD: list everything with its privileges (read-only)', () async {
    final readers = await PcscChannel.listReaders();
    final channel = PcscChannel(readers.firstWhere((r) => r.toLowerCase().contains('contactless')));
    await channel.connect();
    final gp = CardManager(channel, _QuietLog());
    await gp.authenticate(await GpKeys.readConfig(GpKeys.pyApduToolConfig));
    final c = await gp.readCard();

    void line(GpEntry e, String kind) => print('  $kind  ${e.aidText.padRight(32)} ${e.lifeCycleText.padRight(12)} '
        'privileges ${h2(e.privileges)}  ${e.privilegeNames.join(', ')}');

    print('\n=== card manager ===');
    for (final e in c.isd) {
      line(e, 'ISD    ');
    }
    print('\n=== packages ===');
    for (final e in c.packages) {
      line(e, 'package');
      for (final m in e.modules) {
        print('           applet in it: ${Hex.of(m)}');
      }
    }
    print('\n=== installed applets ===');
    for (final e in c.applications) {
      line(e, 'applet ');
    }
    final owner = c.applications.where((a) => a.isDefaultSelected).toList();
    print('\n=== who is "Default selected" ===');
    print(owner.isEmpty ? '  nobody' : owner.map((a) => '  ${a.aidText}').join('\n'));

    // what the card picks by itself after a power-up
    await channel.fieldReset();
    for (final probe in ['80 08 00 00 0A', '00 A4 00 00 02 30 40', '00 B0 00 00 02']) {
      final r = ResponseApdu.fromRaw(await channel.transmit(Hex.parse(probe)));
      print('  after a power-up, $probe -> ${r.swText}${r.data.isEmpty ? '' : ' ${r.data.length} bytes'}');
    }
    await channel.disconnect();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
