// ignore_for_file: avoid_print  -- a console script: printing is how it reports what the card holds.
// READ-ONLY. Asks the card for the numbers that are fixed in the chip and do not change when an applet is burned:
// the CPLC (Card Production Life Cycle) data, the Card Image Number and the Issuer Identification Number.
//   flutter test tool\real_card_chip_id.dart
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

/// The GET DATA objects worth asking for, with what each is meant to hold.
const _objects = <(String, String, String)>[
  ('9F 7F', 'CPLC', 'how and when the chip was made: fabricator, type, serial number, batch'),
  ('00 45', 'Card Image Number (CIN)', 'the number the card issuer gave this card'),
  ('00 42', 'Issuer Identification Number (IIN)', 'who issued the card'),
  ('00 66', 'Card Recognition Data', 'what the card manager is'),
  ('00 E0', 'Key information', 'which key sets the card manager has'),
];

void main() {
  test('REAL CARD: what is fixed in the chip (read-only)', () async {
    final readers = await PcscChannel.listReaders();
    final name = readers.where((r) => r.toLowerCase().contains('contactless')).firstOrNull ?? readers.firstOrNull;
    if (name == null) {
      markTestSkipped('No reader on this PC.');
      return;
    }
    final channel = PcscChannel(name);
    print('Reader: $name');
    await channel.connect();
    print('ATR: ${Hex.of(channel.atr)}');
    print('Reader UID (FF CA): ${Hex.of(await channel.getUid())}  <- random at every tap on this card\n');

    final gp = CardManager(channel, _QuietLog());

    // 1. with the card manager simply selected, no secure channel: many cards answer GET DATA here
    print('--- the card manager selected, no secure channel ---');
    await gp.selectAid(CardManager.defaultIsdAid);
    for (final (tag, label, what) in _objects) {
      final r = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('80 CA $tag 00')));
      print('  ${label.padRight(34)} ${r.swText}  ${r.data.isEmpty ? '' : Hex.of(r.data)}');
      if (r.sw == 0x9000 && tag == '9F 7F') _explainCplc(r.data);
      if (r.sw == 0x9000 && r.data.isNotEmpty) print('      ($what)');
    }

    // 2. inside a secure channel, which some cards insist on
    final keys = await GpKeys.readConfig(GpKeys.pyApduToolConfig);
    print('\n--- inside a secure channel ---');
    try {
      await gp.authenticate(keys);
      for (final (tag, label, what) in _objects) {
        final r = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('80 CA $tag 00')));
        print('  ${label.padRight(34)} ${r.swText}  ${r.data.isEmpty ? '' : Hex.of(r.data)}');
        if (r.sw == 0x9000 && tag == '9F 7F') _explainCplc(r.data);
        if (r.sw == 0x9000 && r.data.isNotEmpty) print('      ($what)');
      }
    } catch (e) {
      print('  could not open a secure channel: $e');
    }
    await channel.disconnect();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// CPLC is 42 bytes of fixed fields, with a 9F 7F tag and a length in front of them.
void _explainCplc(Uint8List raw) {
  var d = raw;
  if (d.length > 3 && d[0] == 0x9F && d[1] == 0x7F) d = Hex.sub(d, 3, d.length - 3);
  if (d.length < 42) {
    print('      CPLC is ${d.length} bytes, expected 42');
    return;
  }
  void show(String name, int at, int len) => print('      ${name.padRight(30)} ${Hex.of(Hex.sub(d, at, len))}');
  show('IC fabricator', 0, 2);
  show('IC type', 2, 2);
  show('Operating system ID', 4, 2);
  show('OS release date', 6, 2);
  show('OS release level', 8, 2);
  show('IC fabrication date', 10, 2);
  show('IC serial number', 12, 4);
  show('IC batch identifier', 16, 2);
  show('IC module fabricator', 18, 2);
  show('IC module packaging date', 20, 2);
  show('ICC manufacturer', 22, 2);
  show('IC embedding date', 24, 2);
  show('IC pre-personalizer', 26, 2);
  show('IC pre-perso. date', 28, 2);
  show('IC pre-perso. equipment', 30, 4);
  show('IC personalizer', 34, 2);
  show('IC personalization date', 36, 2);
  show('IC perso. equipment', 38, 4);
  final serial = Hex.concat([Hex.sub(d, 12, 4), Hex.sub(d, 16, 2)]);
  print('      --> chip serial + batch: ${Hex.compact(serial)}   <- fixed in the chip, survives a re-burn');
}
