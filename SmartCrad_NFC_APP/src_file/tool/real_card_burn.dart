// ignore_for_file: avoid_print  -- a console script: printing is how it reports what the card did.
// ONE-OFF, NOT PART OF THE TEST SUITE. It lives outside test\, so `flutter test` never picks it up and no routine
// test run can change the card.
// Run it on purpose with:
//   flutter test tool\real_card_burn.dart
// It deletes the EMG package from the REAL card and loads it back, to prove the burner's DELETE, INSTALL and LOAD
// commands against a real card rather than only against the tool's own simulator.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/pcsc.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/gp/cap_file.dart';
import 'package:iphone_nfc_tester/gp/card_manager.dart';
import 'package:iphone_nfc_tester/gp/gp_keys.dart';

class _PrintLog implements Logger {
  @override
  void section(String text) => print('\n=== $text');

  @override
  void info(String text) => print('    $text');

  @override
  void warn(String text) => print('  ! $text');

  @override
  void exchange(String label, Uint8List sent, ResponseApdu response, double ms) =>
      print('  >> ${Hex.brief(sent, 16)}  [$label]  << ${response.swText} ${response.data.isEmpty ? '' : '${response.data.length} bytes'}');

  @override
  void blocked(String label, Uint8List typed, String reason) => print('  >> NOT SENT [$label] $reason');
}

const capPath = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\gas_electrometer_javaApplet\Versions\electrical_electrometer_2026-10-01.cap';

void main() {
  test('REAL CARD: delete the package and load it back', () async {
    final readers = await PcscChannel.listReaders();
    print('Readers: $readers');
    final name = readers.firstWhere((r) => r.toLowerCase().contains('contactless'));
    final channel = PcscChannel(name);
    await channel.connect();
    print('Connected to $name, ATR ${Hex.of(channel.atr)}');

    final gp = CardManager(channel, _PrintLog());
    final keys = await GpKeys.readConfig(GpKeys.pyApduToolConfig);
    final cap = await CapFile.read(capPath);
    print('CAP ${cap.name}: package ${Hex.of(cap.packageAid)} v${cap.packageVersion}, '
        'applet ${Hex.of(cap.appletAids.first)}, ${cap.componentBytes} bytes');

    await gp.authenticate(keys.copyWith(keyVersion: 0));
    var contents = await gp.readCard();
    void show(String when) {
      print('\n--- the card $when ---');
      for (final p in contents.packages) {
        print('  package ${p.aidText}  ${p.lifeCycleText}  applets: ${p.modules.map(Hex.of).join(', ')}');
      }
      for (final a in contents.applications) {
        print('  applet  ${a.aidText}  ${a.lifeCycleText}  ${a.privilegeNames.join(', ')}');
      }
    }

    show('before');
    expect(contents.packages.any((p) => Hex.same(p.aid, cap.packageAid)), isTrue, reason: 'the EMG package should be there');

    await gp.delete(cap.packageAid);
    contents = await gp.readCard();
    show('after the delete');
    expect(contents.packages.any((p) => Hex.same(p.aid, cap.packageAid)), isFalse);

    await gp.loadCap(
      cap,
      instanceAid: cap.appletAids.first,
      moduleAid: cap.appletAids.first,
      privileges: 0x04, // default selected, as this card had it
      onProgress: (done, total) {
        if (done == total || done % 10 == 0) print('    LOAD $done/$total');
      },
    );
    contents = await gp.readCard();
    show('after the load');
    expect(contents.packages.any((p) => Hex.same(p.aid, cap.packageAid)), isTrue);
    final applet = contents.applications.firstWhere((a) => Hex.same(a.aid, cap.appletAids.first));
    expect(applet.isDefaultSelected, isTrue, reason: 'the applet must be the default one again');

    // and the applet really answers after a power-up, the way the card is used
    await channel.fieldReset();
    final select = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('00 A4 00 00 02 30 40')));
    print('\nAfter a power-up, SELECT EF 3040 -> ${select.swText}');
    expect(select.sw, 0x9000, reason: 'the applet should be selected by default and answer');
    final read = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('00 B0 00 00 10')));
    print('READ 16 bytes -> ${read.swText} ${Hex.of(read.data)}');
    expect(read.sw, 0x9000);
    final uid = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('80 08 00 00 0A')));
    print('GET UID -> ${uid.swText} ${Hex.of(uid.data)}');

    await channel.disconnect();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
