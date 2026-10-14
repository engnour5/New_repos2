// ignore_for_file: avoid_print  -- a console script: printing is how it reports what the card did.
// ONE-OFF, NOT PART OF THE TEST SUITE. It lives outside test\, so `flutter test` never picks it up.
// Run it on purpose with:
//   flutter test tool\real_card_default_selected.dart
//
// It answers one question on the REAL card: does installing with the "Default selected" privilege actually make the
// card pick the applet after a power-up? It installs the applet BOTH ways and probes the card after each, so the
// answer does not rest on what GET STATUS claims.
//
// The probe: after powering the card down and up, send GET UID (80 08 00 00 0A) without selecting anything first.
// Only the EMG applet answers that with 90 00 and 10 bytes, so a 90 00 means the card selected it by itself.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/pcsc.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/gp/cap_file.dart';
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
  void exchange(String label, Uint8List sent, ResponseApdu response, double ms) {
    if (label.startsWith('LOAD') || label.startsWith('GET STATUS')) return;
    print('    >> ${Hex.brief(sent, 12)}  [$label]  << ${response.swText}');
  }

  @override
  void blocked(String label, Uint8List typed, String reason) {}
}

const capPath = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\gas_electrometer_javaApplet\Versions\electrical_electrometer_2026-10-01.cap';

void main() {
  test('REAL CARD: does the "Default selected" privilege really work?', () async {
    final readers = await PcscChannel.listReaders();
    final channel = PcscChannel(readers.firstWhere((r) => r.toLowerCase().contains('contactless')));
    await channel.connect();
    final gp = CardManager(channel, _QuietLog());
    final keys = await GpKeys.readConfig(GpKeys.pyApduToolConfig);
    final cap = await CapFile.read(capPath);
    final applet = cap.appletAids.first;

    /// Powers the card down and up, then asks GET UID without selecting anything.
    Future<bool> appletIsPickedByItself() async {
      await channel.fieldReset();
      final r = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('80 08 00 00 0A')));
      final picked = r.sw == 0x9000 && r.data.length == 10;
      print('    after a power-up, GET UID -> ${r.swText}'
          '${r.data.isEmpty ? '' : ' ${r.data.length} bytes'}   => applet selected by the card: ${picked ? 'YES' : 'NO'}');
      return picked;
    }

    String privilegesOf(CardContents c) {
      final a = c.applications.where((x) => Hex.same(x.aid, applet)).firstOrNull;
      return a == null ? 'not installed' : '${a.privilegeNames.join(', ')} (byte ${h2(a.privileges)})';
    }

    /// Opens a channel, clears the package if it is there, and installs it again with the given privileges.
    Future<bool> installWith(int privileges) async {
      await gp.authenticate(keys);
      var c = await gp.readCard();
      if (c.packages.any((p) => Hex.same(p.aid, cap.packageAid))) {
        await gp.delete(cap.packageAid);
      } else {
        print('    (the package was not on the card, so there was nothing to delete)');
      }
      await gp.loadCap(cap, instanceAid: applet, moduleAid: applet, privileges: privileges);
      c = await gp.readCard();
      print('    GET STATUS says: ${privilegesOf(c)}');
      return appletIsPickedByItself();
    }

    print('\n=== 0. the card as it is now ===');
    await gp.authenticate(keys);
    final contents = await gp.readCard();
    print('    packages: ${contents.packages.map((p) => p.aidText).join('  |  ')}');
    print('    applets:  ${contents.applications.isEmpty ? '(none)' : contents.applications.map((a) => a.aidText).join('  |  ')}');
    print('    applet ${Hex.of(applet)}: ${privilegesOf(contents)}');
    final before = await appletIsPickedByItself();
    print('    => right now the card is: ${before ? 'picking the applet by itself' : 'NOT picking the applet by itself'}');

    print('\n=== 1. install WITHOUT the Default selected privilege (privileges 00) ===');
    final withoutPrivilege = await installWith(0x00);

    print('\n=== 2. install WITH the Default selected privilege (privileges 04) ===');
    final withPrivilege = await installWith(0x04);

    print('\n=== verdict ===');
    print('    installed with privileges 00 -> card picks it by itself: $withoutPrivilege');
    print('    installed with privileges 04 -> card picks it by itself: $withPrivilege');
    print(withPrivilege && !withoutPrivilege
        ? '    The Default selected privilege works, and it is the privilege that makes the difference.'
        : '    Something is off: see the two lines above.');

    // leave the card the way it should be: the applet installed as the default one
    expect(withPrivilege, isTrue, reason: 'installing with privileges 04 must make the card pick the applet itself');
    expect(withoutPrivilege, isFalse, reason: 'without the privilege the card should NOT pick the applet');

    await channel.disconnect();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
