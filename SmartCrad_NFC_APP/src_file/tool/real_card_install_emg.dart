// ignore_for_file: avoid_print  -- a console script: printing is how it reports what the card did.
// Installs the EMG applet on the REAL card from the built CAP file, deleting an older copy of the package first.
//   flutter test tool\real_card_install_emg.dart
//
// Set [asDefaultApplet] to false when another applet already holds the "Default selected" privilege: a card allows
// only one, and the install is refused with 69 85 otherwise.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/pcsc.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/gp/cap_file.dart';
import 'package:iphone_nfc_tester/gp/card_manager.dart';
import 'package:iphone_nfc_tester/gp/gp_keys.dart';

const asDefaultApplet = false;
const capPath = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\gas_electrometer_javaApplet\Versions\electrical_electrometer_2026-10-01.cap';

class _Log implements Logger {
  @override
  void section(String text) => print('\n=== $text');
  @override
  void info(String text) => print('    $text');
  @override
  void warn(String text) => print('  ! $text');
  @override
  void exchange(String label, Uint8List sent, ResponseApdu response, double ms) {
    if (label.startsWith('LOAD') || label.startsWith('GET STATUS')) return;
    print('    >> ${Hex.brief(sent, 10)}  [$label]  << ${response.swText}');
  }

  @override
  void blocked(String label, Uint8List typed, String reason) {}
}

void main() {
  test('REAL CARD: install the EMG applet', () async {
    final readers = await PcscChannel.listReaders();
    final channel = PcscChannel(readers.firstWhere((r) => r.toLowerCase().contains('contactless')));
    await channel.connect();
    final gp = CardManager(channel, _Log());
    final cap = await CapFile.read(capPath);
    final applet = cap.appletAids.first;

    await gp.authenticate(await GpKeys.readConfig(GpKeys.pyApduToolConfig));
    var c = await gp.readCard();
    final owner = c.applications.where((a) => a.isDefaultSelected).firstOrNull;
    print('    the default selected applet right now: ${owner == null ? 'nobody' : owner.aidText}');

    if (c.packages.any((p) => Hex.same(p.aid, cap.packageAid))) {
      await gp.delete(cap.packageAid);
    }
    await gp.loadCap(cap, instanceAid: applet, moduleAid: applet, privileges: asDefaultApplet ? 0x04 : 0x00);

    c = await gp.readCard();
    final now = c.applications.where((a) => Hex.same(a.aid, applet)).single;
    print('\n    installed ${now.aidText}: ${now.lifeCycleText}, '
        '${now.privilegeNames.isEmpty ? 'no privileges' : now.privilegeNames.join(', ')}');

    await channel.fieldReset();
    final uid = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('80 08 00 00 0A')));
    print('    after a power-up, GET UID -> ${uid.swText}   (the card picks it by itself: ${uid.sw == 0x9000 ? 'YES' : 'NO'})');
    final select = ResponseApdu.fromRaw(await channel.transmit(Hex.concat([
      [0x00, 0xA4, 0x04, 0x00, applet.length],
      applet,
      [0x00],
    ])));
    print('    SELECT by its AID -> ${select.swText}   (an app can reach it: ${select.sw == 0x9000 ? 'YES' : 'NO'})');
    expect(select.sw, 0x9000, reason: 'the applet must at least be selectable by its AID');

    await channel.disconnect();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
