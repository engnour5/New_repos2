// The card manager side: the SCP02 secure channel, CAP file reading, and the burner working on the simulated card.
//
// The SCP02 numbers below were produced by a different implementation (Python with pycryptodome), not by this code,
// so they catch a mistake that the tool and its own simulator would otherwise agree on.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/simulated_card.dart';
import 'package:iphone_nfc_tester/card/simulated_isd.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/gp/cap_file.dart';
import 'package:iphone_nfc_tester/gp/card_manager.dart';
import 'package:iphone_nfc_tester/gp/gp_keys.dart';
import 'package:iphone_nfc_tester/gp/scp02.dart';

class _QuietLog implements Logger {
  final lines = <String>[];

  @override
  void section(String text) => lines.add('=== $text');

  @override
  void info(String text) => lines.add(text);

  @override
  void warn(String text) => lines.add('! $text');

  @override
  void exchange(String label, Uint8List sent, ResponseApdu response, double ms) =>
      lines.add('>> ${Hex.of(sent)} [$label] << ${response.swText}');

  @override
  void blocked(String label, Uint8List typed, String reason) => lines.add('>> ${Hex.of(typed)} [$label] NOT SENT');
}

/// A CAP file to load in the tests. The built applet is used when it is there.
final _capPaths = [
  r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\gas_electrometer_javaApplet\Versions\electrical_electrometer_2026-10-01.cap',
  r'D:\Applet_Card_G2\gas_electrometer_javaApplet\bin\Debug\electrical_electrometer\javacard\electrical_electrometer.cap',
  r'D:\Applet_Card_G2\gas_electrometer_javaApplet\Tool\PyApduTool_Release\EGAS.cap',
];
String? get _capPath => _capPaths.where((p) => File(p).existsSync()).firstOrNull;

/// A second package, for what happens with two on the card.
final _egasPaths = [
  r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\PyApduTool_Release\EGAS_old_CAP(249_issue).cap',
  r'D:\Applet_Card_G2\gas_electrometer_javaApplet\Tool\PyApduTool_Release\EGAS.cap',
];
String? get _egasPath => _egasPaths.where((p) => File(p).existsSync()).firstOrNull;

/// The simulated card with its card manager selected and an SCP02 channel open, done by hand, so a test can send
/// card-manager commands the tool itself would never send.
Future<(SimulatedCard, Scp02Session)> _rawChannel() async {
  final card = SimulatedCard(delay: Duration.zero, keys: GpKeys.factoryKey());
  await card.connect();
  ResponseApdu send(List<int> apdu) => ResponseApdu.fromRaw(card.transmitNow(Uint8List.fromList(apdu)));
  expect(send([0x00, 0xA4, 0x04, 0x00, SimulatedIsd.aid.length, ...SimulatedIsd.aid, 0x00]).sw, 0x9000);
  final host = Uint8List(8);
  final init = InitializeUpdateResponse(send([0x80, 0x50, 0x00, 0x00, 0x08, ...host, 0x00]).data);
  final k = GpKeys.factoryKey();
  final s = Scp02Session.fromStaticKeys(k.enc, k.mac, k.dek, init.sequenceCounter);
  expect(send(s.wrap(0x80, 0x82, 0x01, 0x00, hostCryptogram(s.sEnc, init.cardChallenge, host))).sw, 0x9000);
  s.open = true;
  return (card, s);
}

void main() {
  group('SCP02', () {
    final key = Hex.parse('404142434445464748494A4B4C4D4E4F');
    const sequence = 0x0020;
    final hostChallenge = Hex.parse('0001020304050607');
    final cardChallenge = Hex.parse('0020AABBCCDDEEFF'); // the counter and the card's 6 random bytes

    test('the session keys match an independent implementation', () {
      final s = Scp02Session.fromStaticKeys(key, key, key, sequence);
      expect(Hex.compact(s.sEnc), 'B87D48485A1B030B19C7938D541BE8BD');
      expect(Hex.compact(s.sMac), '2E3DB96B8B231CF187D8D9857FA0F701');
      expect(Hex.compact(s.sDek), 'DA5A7DA037C2A29F8CA02652660F3438');
    });

    test('the cryptograms match an independent implementation', () {
      final s = Scp02Session.fromStaticKeys(key, key, key, sequence);
      expect(Hex.compact(cardCryptogram(s.sEnc, hostChallenge, cardChallenge)), '7AE9BFB69D92F1E3');
      expect(Hex.compact(hostCryptogram(s.sEnc, cardChallenge, hostChallenge)), '0A652F3CF57B982D');
    });

    test('the C-MAC and the chained ICV match an independent implementation', () {
      final s = Scp02Session.fromStaticKeys(key, key, key, sequence);
      final host = hostCryptogram(s.sEnc, cardChallenge, hostChallenge);
      // EXTERNAL AUTHENTICATE is the first command of the session, so its ICV is zero
      final wrapped = s.wrap(0x80, 0x82, 0x01, 0x00, host);
      expect(Hex.compact(wrapped), '84820100100A652F3CF57B982D26545781FC0D92AD');
      // the next command starts from the previous MAC, encrypted with the first half of the MAC session key
      final next = s.wrap(0x80, 0xF2, 0x40, 0x00, Hex.parse('4F00'), le: 0x00);
      expect(Hex.compact(next), '84F240000A4F001A17434D4939722D00');
    });

    test('padding always adds a block when the data already fits', () {
      expect(Hex.compact(pad80(Hex.parse('0102'))), '0102800000000000');
      expect(Hex.compact(pad80(Hex.parse('0102030405060708'))), '01020304050607088000000000000000');
      expect(pad80(Uint8List(0)).length, 8);
    });

    test('a command that would not fit with its MAC is refused rather than truncated', () {
      final s = Scp02Session.fromStaticKeys(key, key, key, sequence);
      expect(() => s.wrap(0x80, 0xE8, 0x00, 0x00, Uint8List(248)), throwsArgumentError);
      expect(s.wrap(0x80, 0xE8, 0x00, 0x00, Uint8List(247)).length, 5 + 247 + 8);
    });
  });

  group('key file', () {
    Future<File> write(String text) async {
      final dir = await Directory.systemTemp.createTemp('nfc_tester_keys');
      addTearDown(() => dir.delete(recursive: true));
      return File('${dir.path}\\config.ini')..writeAsStringSync(text);
    }

    test('only the three keys are taken from a config.ini; everything else in it is ignored', () async {
      final file = await write('''
[ReaderWindow]
lastreader = PCSC Reader
lastparams = {"reader": "Identive"}

[ControlCenter]
authkey = 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F
cmackey = 101112131415161718191A1B1C1D1E1F
dekkey = 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F
keyversion = 1

[ApduWindow]
history = 00 B0 00 00 02|80 08 00 00 0A
''');
      final keys = await GpKeys.readConfig(file.path);
      expect(Hex.compact(keys.enc), '000102030405060708090A0B0C0D0E0F');
      expect(Hex.compact(keys.mac), '101112131415161718191A1B1C1D1E1F');
      expect(Hex.compact(keys.dek), '202122232425262728292A2B2C2D2E2F');
      expect(keys.keyVersion, 1);
      expect(keys.usable, isTrue);
      expect(keys.masked, isNot(contains('0001'))); // what may be shown never holds a key
    });

    test('a key version is not needed, and defaults to "any"', () async {
      final file = await write('[ControlCenter]\nauthkey = ${'00' * 16}\ncmackey = ${'11' * 16}\ndekkey = ${'22' * 16}\n');
      expect((await GpKeys.readConfig(file.path)).keyVersion, 0);
    });

    test('a key of the wrong length or a missing one is refused with a clear message', () async {
      final short = await write('[ControlCenter]\nauthkey = 00 01 02\ncmackey = ${'11' * 16}\ndekkey = ${'22' * 16}\n');
      expect(() => GpKeys.readConfig(short.path), throwsA(isA<FormatException>()));
      final missing = await write('[ControlCenter]\nauthkey = ${'00' * 16}\n');
      expect(() => GpKeys.readConfig(missing.path), throwsA(isA<FormatException>()));
      expect(() => GpKeys.readConfig(r'C:\no\such\file.ini'), throwsA(isA<FileSystemException>()));
    });

    test('a config.ini saved with a byte order mark and Windows line ends is read the same', () async {
      final file = await write('\uFEFF[ControlCenter]\r\nauthkey = ${'0A' * 16}\r\ncmackey = ${'0B' * 16}\r\ndekkey = ${'0C' * 16}\r\n');
      final keys = await GpKeys.readConfig(file.path);
      expect(Hex.compact(keys.mac), '0B' * 16);
    });
  });

  group('the default test key', () {
    // the keys are the card's secret: they are compared here, never printed, so a failure cannot show one
    bool sameKeys(GpKeys a, GpKeys b) => Hex.same(a.enc, b.enc) && Hex.same(a.mac, b.mac) && Hex.same(a.dek, b.dek);

    test('is the key set of PyApduTool\'s config.ini, found in the Tools folder next to the app', () async {
      final d = GpKeys.defaultTestKey();
      if (d.file == null) {
        markTestSkipped('No PyApduTool config.ini on this PC.');
        return;
      }
      expect(sameKeys(d.keys, await GpKeys.readConfig(d.file!)), isTrue);
      // src_file (and App_file) sit in Tools\SmartCrad_NFC_APP, and PyApduTool in Tools\PyApduTool_Release
      final nextToApp = '${Directory.current.parent.parent.path}\\PyApduTool_Release\\config.ini';
      if (File(nextToApp).existsSync()) expect(d.file, nextToApp);
      expect(GpKeys.pyApduToolConfig, d.file);
    });

    test('opens the simulated card, which holds the same keys as the test card', () async {
      final d = GpKeys.defaultTestKey();
      final card = SimulatedCard(delay: Duration.zero);
      await card.connect();
      final gp = CardManager(card, _QuietLog());
      await gp.authenticate(d.keys);
      expect(gp.open, isTrue);
      expect(gp.initializeUpdate!.keyVersion, 1, reason: 'the test card keeps its key set under key version 1');
      expect((await gp.readCard()).applications.single.asText, 'EMG0000000');
      // the same keys as read by "From a config.ini" open it as well
      if (d.file != null) {
        await gp.authenticate(await GpKeys.readConfig(d.file!));
        expect(gp.open, isTrue);
      }
      // and another key set does not, so the simulator still checks the keys as a card does
      if (!sameKeys(d.keys, GpKeys.factoryKey())) {
        await expectLater(gp.authenticate(GpKeys.factoryKey()), throwsA(isA<GpKeyException>()));
        expect(gp.open, isFalse);
      }
    });
  });

  group('CAP file', () {
    test('reads the package AID, the applet AIDs and the components in load order', () async {
      final path = _capPath;
      if (path == null) {
        markTestSkipped('No CAP file on this PC to read.');
        return;
      }
      final cap = await CapFile.read(path);
      expect(cap.packageAid.length, greaterThanOrEqualTo(5));
      expect(cap.appletAids, isNotEmpty);
      // Descriptor and Debug are in the file but must not be loaded
      expect(cap.componentNames, isNot(contains('Descriptor')));
      expect(cap.componentNames, isNot(contains('Debug')));
      expect(cap.componentNames.first, 'Header');
      expect(cap.componentNames, contains('Method'));

      final block = cap.loadFileDataBlock();
      expect(block[0], 0xC4); // the Load File Data Block tag
      expect(block.length, greaterThan(cap.componentBytes));
      // the block carries exactly the components, after the tag and its BER length
      final headerStart = block[1] == 0x82 ? 4 : (block[1] == 0x81 ? 3 : 2);
      expect(block[headerStart], 1); // the Header component comes first
      expect(cap.loadBlocks(blockSize: 240).fold<int>(0, (n, b) => n + b.length), block.length);
      expect(cap.loadBlocks(blockSize: 240).every((b) => b.length <= 240), isTrue);
    });

    test('a file that is not a CAP is refused with a clear message', () {
      expect(() => CapFile.parse('x.cap', Uint8List.fromList(List.filled(40, 0x41))), throwsFormatException);
    });
  });

  group('card manager on the simulated card', () {
    Future<(SimulatedCard, CardManager, _QuietLog)> connected() async {
      final card = SimulatedCard(delay: Duration.zero, keys: GpKeys.factoryKey());
      final log = _QuietLog();
      await card.connect();
      return (card, CardManager(card, log), log);
    }

    test('a wrong key set is refused before anything is sent, and the channel stays shut', () async {
      final (_, gp, _) = await connected();
      final wrong = GpKeys(
        enc: Hex.parse('000102030405060708090A0B0C0D0E0F'),
        mac: Hex.parse('000102030405060708090A0B0C0D0E0F'),
        dek: Hex.parse('000102030405060708090A0B0C0D0E0F'),
      );
      await expectLater(gp.authenticate(wrong), throwsA(isA<GpException>()));
      expect(gp.open, isFalse);
      // the card's own proof failed, so EXTERNAL AUTHENTICATE was never sent
      await expectLater(gp.readCard(), throwsA(isA<GpException>()));
    });

    test('authenticate, then read the card manager, the applet and the package', () async {
      final (card, gp, _) = await connected();
      await gp.authenticate(GpKeys.factoryKey());
      expect(gp.open, isTrue);
      expect(gp.initializeUpdate!.scpId, 0x02);

      final contents = await gp.readCard();
      expect(contents.isd.single.aidText, Hex.of(SimulatedIsd.aid));
      expect(contents.isd.single.privilegeNames, contains('Security Domain'));

      final applet = contents.applications.single;
      expect(applet.aidText, Hex.of(Hex.parse('454D4730303030303030')));
      expect(applet.asText, 'EMG0000000');
      expect(applet.lifeCycleText, 'SELECTABLE');
      expect(applet.isDefaultSelected, isTrue);

      final package = contents.packages.single;
      expect(package.aidText, Hex.of(SimulatedCard.packageAid));
      expect(package.lifeCycleText, 'LOADED');
      expect(package.modules.single, applet.aid);
      expect(card.isd.applets, hasLength(1));
    });

    test('deleting the package takes its applet with it, and the card then has no default applet', () async {
      final (card, gp, _) = await connected();
      await gp.authenticate(GpKeys.factoryKey());

      // without "and related objects" the card keeps the package, because its applet is still installed
      await expectLater(gp.delete(SimulatedCard.packageAid, withRelated: false), throwsA(isA<GpException>()));
      expect(card.isd.packages, hasLength(1));

      await gp.delete(SimulatedCard.packageAid);
      final after = await gp.readCard();
      expect(after.packages, isEmpty);
      expect(after.applications, isEmpty);

      // the applet is really gone: a tap no longer finds it
      await card.fieldReset();
      expect(ResponseApdu.fromRaw(await card.transmit(Hex.parse('00 A4 04 00 0A 45 4D 47 30 30 30 30 30 30 30 00'))).sw,
          isNot(0x9000));
      await expectLater(gp.delete(SimulatedCard.packageAid), throwsA(isA<GpException>())); // nothing left to delete
    });

    test('loading a CAP file puts the package back and installs it as the default applet', () async {
      final path = _capPath;
      if (path == null) {
        markTestSkipped('No CAP file on this PC to load.');
        return;
      }
      final cap = await CapFile.read(path);
      final (card, gp, _) = await connected();
      await gp.authenticate(GpKeys.factoryKey());

      // the card refuses a package it already has, which is why the screen deletes first
      await expectLater(
        gp.loadCap(cap, instanceAid: cap.appletAids.first, moduleAid: cap.appletAids.first),
        throwsA(isA<GpException>()),
      );

      await gp.delete(SimulatedCard.packageAid);
      final progress = <int>[];
      await gp.loadCap(
        cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        privileges: 0x04, // default selected, as the test card has it
        onProgress: (done, total) => progress.add(done),
      );
      expect(progress, isNotEmpty);
      expect(progress.last, progress.length);

      final after = await gp.readCard();
      expect(after.packages.single.aidText, Hex.of(cap.packageAid));
      expect(after.applications.single.isDefaultSelected, isTrue);

      // and the applet answers again after a power-up
      await card.fieldReset();
      expect(ResponseApdu.fromRaw(await card.transmit(Hex.parse('00 A4 00 00 02 30 40'))).sw, 0x9000);
    });

    test('only one applet can be the default selected one, and the card says so', () async {
      final path = _capPath;
      if (path == null) {
        markTestSkipped('No CAP file on this PC to load.');
        return;
      }
      final cap = await CapFile.read(path);
      final (card, gp, _) = await connected();
      await gp.authenticate(GpKeys.factoryKey());

      // another applet holds the privilege, as EGAS does on the real test card
      card.isd.applets.single.privileges = 0x04;
      card.isd.packages.removeWhere((p) => Hex.same(p.aid, cap.packageAid));
      card.isd.applets.removeWhere((a) => Hex.same(a.packageAid, cap.packageAid));
      card.isd.preload(
        packageAid: Hex.parse('A0 00 00 00 03 45 47 41 53'),
        moduleAid: Hex.parse('A0 00 00 00 03 45 47 41 53 00'),
        instanceAid: Hex.parse('A0 00 00 00 03 45 47 41 53 00'),
      );

      await expectLater(
        gp.loadCap(cap, instanceAid: cap.appletAids.first, moduleAid: cap.appletAids.first, privileges: 0x04),
        throwsA(isA<GpException>().having((e) => e.message, 'message', contains('only one applet with that privilege'))),
      );

      // without the privilege the same load goes through
      await gp.delete(cap.packageAid);
      await gp.loadCap(cap, instanceAid: cap.appletAids.first, moduleAid: cap.appletAids.first);
      final after = await gp.readCard();
      expect(after.applications.where((a) => Hex.same(a.aid, cap.appletAids.first)).single.isDefaultSelected, isFalse);
      expect(after.applications.where((a) => a.isDefaultSelected), hasLength(1));
    });

    test('a command outside the secure channel is refused by the card manager', () async {
      final (card, _, _) = await connected();
      await card.transmit(Hex.concat([
        [0x00, 0xA4, 0x04, 0x00, SimulatedIsd.aid.length],
        SimulatedIsd.aid,
        [0x00],
      ]));
      // GET STATUS without a C-MAC: the card manager will not answer it
      final r = ResponseApdu.fromRaw(await card.transmit(Hex.parse('80 F2 40 00 02 4F 00 00')));
      expect(r.sw, 0x6982);
    });

    test('key version "any" and 1 open the simulated card, as on the test card; another one is refused clearly', () async {
      final (_, gp, _) = await connected();
      await gp.authenticate(GpKeys.factoryKey()); // "any"
      expect(gp.initializeUpdate!.keyVersion, 1);
      await gp.authenticate(GpKeys.factoryKey().copyWith(keyVersion: 1));
      expect(gp.open, isTrue);
      await expectLater(
        gp.authenticate(GpKeys.factoryKey().copyWith(keyVersion: 2)),
        throwsA(isA<GpKeyException>().having((e) => e.message, 'message', contains('no key set with key version 2'))),
      );
      expect(gp.open, isFalse);
    });

    test('a new install gives the applet a new card ID and a file of 00, as on the real card', () async {
      final path = _capPath;
      if (path == null) {
        markTestSkipped('No CAP file on this PC to load.');
        return;
      }
      final cap = await CapFile.read(path);
      final (card, gp, _) = await connected();
      Future<ResponseApdu> send(String hex) async => ResponseApdu.fromRaw(await card.transmit(Hex.parse(hex)));

      // the card arrives with its demo data
      final idBefore = (await send('80 08 00 00 0A')).data;
      await send('00 A4 00 00 02 30 40');
      expect(String.fromCharCodes((await send('00 B0 00 10 1A')).data), 'EMG METER CARD - SIMULATOR');

      await gp.authenticate(GpKeys.factoryKey());
      await gp.delete(SimulatedCard.packageAid);
      await gp.loadCap(cap, instanceAid: cap.appletAids.first, moduleAid: cap.appletAids.first, privileges: 0x04);

      await card.fieldReset();
      final idAfter = (await send('80 08 00 00 0A')).data;
      expect(idAfter, hasLength(10));
      expect(Hex.same(idAfter, idBefore), isFalse, reason: 'install() makes a new random card ID');
      await send('00 A4 00 00 02 30 40');
      expect((await send('00 B0 00 00 00')).data, everyElement(0));
      expect((await send('00 B0 7F FF 01')).data, [0x00]);
      // the ID belongs to the applet, so it stays the same over power-ups
      await card.fieldReset();
      expect((await send('80 08 00 00 0A')).data, idAfter);
    });

    test('an applet of another package keeps memory of its own', () async {
      final egasPath = _egasPath;
      if (egasPath == null) {
        markTestSkipped('No second CAP file on this PC to load.');
        return;
      }
      final egas = await CapFile.read(egasPath);
      final (card, gp, _) = await connected();
      Future<ResponseApdu> send(String hex) async => ResponseApdu.fromRaw(await card.transmit(Hex.parse(hex)));
      final emgId = (await send('80 08 00 00 0A')).data;

      await gp.authenticate(GpKeys.factoryKey());
      await gp.loadCap(egas, instanceAid: egas.appletAids.first, moduleAid: egas.appletAids.first);

      // EMG is still the default applet, with the same card ID and its data
      await card.fieldReset();
      expect((await send('80 08 00 00 0A')).data, emgId);
      await send('00 A4 00 00 02 30 40');
      expect(String.fromCharCodes((await send('00 B0 00 10 1A')).data), 'EMG METER CARD - SIMULATOR');
      // and the new applet has its own
      expect((await send('00 A4 04 00 0A ${Hex.of(egas.appletAids.first)} 00')).sw, 0x9000);
      final egasId = (await send('80 08 00 00 0A')).data;
      expect(egasId, hasLength(10));
      expect(Hex.same(egasId, emgId), isFalse);
    });

    test('with no default applet the card manager is selected after a power-up, as GlobalPlatform has it', () async {
      final (card, gp, _) = await connected();
      await gp.authenticate(GpKeys.factoryKey());
      await gp.delete(SimulatedCard.packageAid);
      await card.fieldReset();
      int sw(String hex) => ResponseApdu.fromRaw(card.transmitNow(Hex.parse(hex))).sw;
      expect(sw('00 A4 04 00 0A 45 4D 47 30 30 30 30 30 30 30 00'), 0x6A82); // the applet is not on the card
      expect(sw('00 B0 00 00 10'), 0x6D00); // the card manager has no READ BINARY
      expect(sw('80 08 00 00 0A'), 0x6D00);
      expect(sw('80 F2 40 00 02 4F 00 00'), 0x6982); // its own commands still need the secure channel
      // a channel opens straight away, and the card is empty
      await gp.authenticate(GpKeys.factoryKey());
      final c = await gp.readCard();
      expect(c.packages, isEmpty);
      expect(c.applications, isEmpty);
    });

    test('GET STATUS that does not fit in one answer is read to the end with "get next"', () async {
      final (card, gp, log) = await connected();
      card.isd.statusPageBytes = 24; // room for one or two entries per answer
      for (var i = 0; i < 5; i++) {
        final aid = Hex.parse('A0 00 00 00 99 0$i');
        card.isd.preload(packageAid: aid, moduleAid: Hex.concat([aid, [0x01]]), instanceAid: Hex.concat([aid, [0x01]]), privileges: 0);
      }
      await gp.authenticate(GpKeys.factoryKey());
      final c = await gp.readCard();
      expect(c.packages, hasLength(6));
      expect(c.applications, hasLength(6));
      expect(c.packages.last.modules.single, Hex.parse('A0 00 00 00 99 04 01'));
      expect(c.applications.where((a) => a.isDefaultSelected), hasLength(1));
      expect(log.lines.where((l) => l.endsWith('<< 63 10')), isNotEmpty, reason: 'the card should have said "more follow"');
    });

    test('the card refuses LOAD blocks out of order, and a load that does not add up', () async {
      final path = _capPath;
      if (path == null) {
        markTestSkipped('No CAP file on this PC to load.');
        return;
      }
      final cap = await CapFile.read(path);
      final (card, s) = await _rawChannel();
      int sw(Uint8List apdu) => ResponseApdu.fromRaw(card.transmitNow(apdu)).sw;
      Uint8List forLoad(Uint8List package) => s.wrap(0x80, 0xE6, 0x02, 0x00, Hex.concat([[package.length], package, [0, 0, 0, 0]]), le: 0);
      int load(Uint8List lfdb) {
        final blocks = [for (var o = 0; o < lfdb.length; o += 240) Hex.sub(lfdb, o, o + 240 > lfdb.length ? lfdb.length - o : 240)];
        var last = 0x9000;
        for (var i = 0; i < blocks.length && last == 0x9000; i++) {
          last = sw(s.wrap(0x80, 0xE8, i == blocks.length - 1 ? 0x80 : 0x00, i, blocks[i], le: 0));
        }
        return last;
      }

      expect(sw(s.wrap(0x80, 0xE4, 0x00, 0x80, Hex.concat([[0x4F, cap.packageAid.length], cap.packageAid]), le: 0)), 0x9000);
      final all = cap.loadFileDataBlock();

      // block 1 before block 0: the card gives up on the load
      expect(sw(forLoad(cap.packageAid)), 0x9000);
      expect(sw(s.wrap(0x80, 0xE8, 0x00, 0x01, Hex.sub(all, 0, 240), le: 0)), 0x6A86);
      expect(sw(s.wrap(0x80, 0xE8, 0x00, 0x00, Hex.sub(all, 0, 240), le: 0)), 0x6985, reason: 'nothing is being loaded now');

      // one byte short of what the C4 length says
      expect(sw(forLoad(cap.packageAid)), 0x9000);
      expect(load(Hex.sub(all, 0, all.length - 1)), 0x6A80);

      // a package other than the one INSTALL [for load] announced
      expect(sw(forLoad(Hex.parse('A0 00 00 00 01 02 03'))), 0x9000);
      expect(load(all), 0x6A80);
      expect(card.isd.packages, isEmpty);

      // the right package, in order, goes through
      expect(sw(forLoad(cap.packageAid)), 0x9000);
      expect(load(all), 0x9000);
      expect(card.isd.packages.single.modules.single, cap.appletAids.first);
    });

    test('a wrong C-MAC ends the secure channel', () async {
      final (card, s) = await _rawChannel();
      int sw(Uint8List apdu) => ResponseApdu.fromRaw(card.transmitNow(apdu)).sw;
      final good = s.wrap(0x80, 0xF2, 0x40, 0x00, Hex.parse('4F 00'), le: 0);
      final bad = Uint8List.fromList(good)..[good.length - 2] ^= 0x01; // the last byte of the MAC
      expect(sw(bad), 0x6982);
      expect(card.isd.open, isFalse);
      expect(sw(s.wrap(0x80, 0xF2, 0x40, 0x00, Hex.parse('4F 00'), le: 0)), 0x6982);
    });
  });
}
