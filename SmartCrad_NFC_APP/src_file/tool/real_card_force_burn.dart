// ignore_for_file: avoid_print  -- a console script: printing is how it reports what the card did.
// ONE-OFF, outside test\ so `flutter test` never runs it. It burns the EMG CAP onto the REAL card with FORCE: it
// deletes whatever already uses the instance AID (and any default-selected applet) first, then installs. This is the
// case the Auto load log failed on ("an applet with the AID ... is already on the card").
//   flutter test tool\real_card_force_burn.dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/pcsc.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/gp/cap_file.dart';
import 'package:iphone_nfc_tester/gp/card_manager.dart';
import 'package:iphone_nfc_tester/gp/cplc.dart';
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
  test('REAL CARD: FORCE burn over whatever is already there', () async {
    final readers = await PcscChannel.listReaders();
    print('Readers: $readers');
    final name = readers.firstWhere((r) => r.toLowerCase().contains('contactless'));
    final channel = PcscChannel(name);
    await channel.connect();
    print('Connected to $name, ATR ${Hex.of(channel.atr)}');

    final gp = CardManager(channel, _PrintLog());
    final cap = await CapFile.read(capPath);
    final instance = cap.appletAids.first;
    print('CAP ${cap.name}: package ${Hex.of(cap.packageAid)}, install as ${Hex.of(instance)}, ${cap.componentBytes} bytes');

    // which card is this (the chip ID never changes), read before anything
    try {
      await gp.selectAid(gp.isdAid);
      final chip = await Cplc.read(channel);
      if (chip != null) print('Chip ID: ${chip.chipId}${chip.fabricator.isEmpty ? '' : ' (${chip.fabricator})'}');
    } catch (_) {}

    await gp.authenticate((await GpKeys.readConfig(GpKeys.pyApduToolConfig)).copyWith(keyVersion: 0));
    var contents = await gp.readCard();
    void show(String when) {
      print('\n--- the card $when ---');
      for (final p in contents.packages) {
        print('  package ${p.aidText}  ${p.lifeCycleText}  applets: ${p.modules.map(Hex.of).join(', ')}');
      }
      for (final a in contents.applications) {
        print('  applet  ${a.aidText}  ${a.lifeCycleText}  ${a.privilegeNames.join(', ')}');
      }
      final owner = contents.applications.where((a) => a.isDefaultSelected).map((a) => a.aidText).join(', ');
      print('  default selected: ${owner.isEmpty ? 'nobody' : owner}');
    }

    show('BEFORE');

    // FORCE: delete whatever stands in the way, then install — the same thing the Force checkbox does
    final blockers = contents.blockers(cap.packageAid, instanceAid: instance, defaultSelected: true);
    print('\nForce will delete ${blockers.isEmpty ? '(nothing in the way)' : blockers.map((b) => Hex.of(b.$1)).join(', ')}');
    for (final (aid, withRelated) in blockers) {
      print('  deleting ${Hex.of(aid)}${withRelated ? ' and what came from it' : ''} ...');
      try {
        await gp.delete(aid, withRelated: withRelated);
      } on GpException catch (e) {
        if (e.sw != 0x6A88) rethrow; // 6A 88 = already gone
        print('    (it was already gone)');
      }
    }

    await gp.loadCap(cap, instanceAid: instance, moduleAid: instance, privileges: 0x04, onProgress: (d, t) {
      if (d == t || d % 20 == 0) print('    LOAD $d/$t');
    });

    contents = await gp.readCard();
    show('AFTER');
    final applet = contents.applications.firstWhere((a) => Hex.same(a.aid, instance));
    expect(applet.isDefaultSelected, isTrue, reason: 'the new applet is installed and default-selected');
    expect(contents.packages.any((p) => Hex.same(p.aid, cap.packageAid)), isTrue, reason: 'the EMG package is on the card');

    // and it answers after a power-up, the way the card is used
    await channel.fieldReset();
    final uid = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('80 08 00 00 0A')));
    print('\nAfter a power-up, GET UID -> ${uid.swText} ${Hex.of(uid.data)}  (the fresh card ID)');
    final sel = ResponseApdu.fromRaw(await channel.transmit(Hex.parse('00 A4 00 00 02 30 40')));
    print('SELECT EF 3040 -> ${sel.swText}');
    expect(sel.sw, 0x9000, reason: 'the applet is selected by default and answers');

    await channel.disconnect();
    print('\nDONE: the card that used to be refused now holds the applet, default-selected.');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
