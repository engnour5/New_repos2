// ignore_for_file: avoid_print  -- a console script: printing is how it reports what the card did.
// Makes the EMG applet the default selected one on the REAL card: the applet that holds that privilege loses it
// (its instance is deleted; its package stays loaded), then EMG is installed with the privilege.
//   flutter test tool\real_card_emg_default.dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/pcsc.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/gp/cap_file.dart';
import 'package:iphone_nfc_tester/gp/card_manager.dart';
import 'package:iphone_nfc_tester/gp/gp_keys.dart';

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
  test('REAL CARD: make the EMG applet the default selected one', () async {
    final readers = await PcscChannel.listReaders();
    final channel = PcscChannel(readers.firstWhere((r) => r.toLowerCase().contains('contactless')));
    await channel.connect();
    final gp = CardManager(channel, _Log());
    final cap = await CapFile.read(capPath);
    final applet = cap.appletAids.first;

    await gp.authenticate(await GpKeys.readConfig(GpKeys.pyApduToolConfig));
    var c = await gp.readCard();
    for (final a in c.applications) {
      print('    applet ${a.aidText}  ${a.privilegeNames.join(', ')}');
    }

    // whoever holds the privilege has to give it up: only one applet on a card can have it
    for (final owner in c.applications.where((a) => a.isDefaultSelected && !Hex.same(a.aid, applet))) {
      print('\n    ${owner.aidText} holds "Default selected": deleting that applet instance '
          '(its package stays loaded, so it can be installed again later)');
      await gp.delete(owner.aid, withRelated: false);
    }

    c = await gp.readCard();
    if (c.packages.any((p) => Hex.same(p.aid, cap.packageAid))) await gp.delete(cap.packageAid);
    await gp.loadCap(cap, instanceAid: applet, moduleAid: applet, privileges: 0x04);

    c = await gp.readCard();
    print('\n--- the card now ---');
    for (final p in c.packages) {
      print('    package ${p.aidText}  ${p.lifeCycleText}');
    }
    for (final a in c.applications) {
      print('    applet  ${a.aidText}  ${a.lifeCycleText}  ${a.privilegeNames.join(', ')}');
    }

    await channel.fieldReset();
    final uid = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('80 08 00 00 0A')));
    print('\n    after a power-up, GET UID -> ${uid.swText}${uid.data.isEmpty ? '' : ' ${Hex.of(uid.data)}'}');
    final read = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('00 B0 00 00 02')));
    print('    READ before SELECT 3040 -> ${read.swText}  (69 86 is right: the applet is selected and wants its file first)');

    expect(uid.sw, 0x9000, reason: 'the card must pick the EMG applet by itself after a power-up');
    expect(uid.data.length, 10);
    expect(read.sw, 0x6986);
    await channel.disconnect();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
