// Auto load: burning the same CAP onto one card after another. One press, then only the cards change.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/card_channel.dart';
import 'package:iphone_nfc_tester/card/simulated_card.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/batch_report.dart';
import 'package:iphone_nfc_tester/core/errors.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/gp/batch_burn.dart';
import 'package:iphone_nfc_tester/gp/card_manager.dart';
import 'package:iphone_nfc_tester/gp/cap_file.dart';
import 'package:iphone_nfc_tester/gp/cplc.dart';
import 'package:iphone_nfc_tester/gp/gp_keys.dart';
import 'package:iphone_nfc_tester/main.dart';
import 'package:iphone_nfc_tester/state/app_state.dart';
import 'package:iphone_nfc_tester/ui/pages/burner_page.dart';

class _Log implements Logger {
  final lines = <String>[];

  @override
  void section(String t) => lines.add('=== $t');
  @override
  void info(String t) => lines.add(t);
  @override
  void warn(String t) => lines.add('! $t');
  @override
  void exchange(String label, Uint8List sent, ResponseApdu r, double ms) {}
  @override
  void blocked(String label, Uint8List typed, String reason) {}
}

final _cap = [
  r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\gas_electrometer_javaApplet\Versions\electrical_electrometer_2026-10-01.cap',
  r'D:\Applet_Card_G2\gas_electrometer_javaApplet\bin\Debug\electrical_electrometer\javacard\electrical_electrometer.cap',
].where((p) => File(p).existsSync()).firstOrNull;

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final file = File('C:\\Windows\\Fonts\\$f');
    if (file.existsSync()) loader.addFont(Future.value(ByteData.view(Uint8List.fromList(file.readAsBytesSync()).buffer)));
  }
  await loader.load();
}

/// A reader that behaves like the real PC/SC one, which is what the simulated card does NOT do:
///
/// - `connect()` hands back the connection it already has **without looking at the card**, exactly as
///   `_PcscState._open` returns a cached `_Connection`. Only a connect made after a disconnect really asks.
/// - with no card on it, a real connect fails with "no card" (0x8010000C).
/// - a command sent while the card is off the reader fails too.
///
/// Cards are swapped by setting [cardOnReader]; each new card is a fresh one.
class _FakeReader implements CardChannel {
  _FakeReader(this.inner);

  SimulatedCard inner;
  bool cardOnReader = true;
  bool connected = false;

  /// Every connect that really went to the reader, so a test can show the cache is not being trusted.
  int realConnects = 0;

  /// Called on every connect that really goes to the reader, so a test can count the looks.
  void Function()? onLook;

  @override
  String get name => 'Fake PC/SC reader';
  @override
  bool get isSimulated => false; // the batch burner must treat it as real hardware
  @override
  Uint8List? get atr => connected ? inner.atr : null;

  @override
  Future<void> connect() async {
    if (connected) return; // the cached handle, as winscard does
    realConnects++;
    onLook?.call();
    if (!cardOnReader) throw CardException('There is no card on the reader.', 0x8010000C);
    connected = true;
    await inner.connect();
  }

  @override
  Future<void> disconnect() async {
    connected = false;
    await inner.disconnect();
  }

  @override
  Future<void> fieldReset() async {
    if (!cardOnReader) throw CardException('The card was removed.', 0x80100069);
    await inner.fieldReset();
  }

  @override
  Future<Uint8List> transmit(Uint8List apdu) async {
    if (!cardOnReader) throw CardException('The card was removed.', 0x80100069);
    return inner.transmit(apdu);
  }

  @override
  Future<Uint8List?> getUid() async => cardOnReader ? inner.getUid() : null;

  @override
  Future<void> dispose() async {}

  /// The operator takes the card off the reader.
  void takeOff() {
    cardOnReader = false;
    connected = false;
  }

  /// The operator puts the next, untouched card on.
  void putNextOn() {
    inner = SimulatedCard(delay: Duration.zero);
    cardOnReader = true;
    connected = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await _loadFont('Segoe UI', ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf', 'segoeuii.ttf']);
    await _loadFont('Consolas', ['consola.ttf', 'consolab.ttf']);
  });

  group('the batch burner', () {
    test('burns one card after another and counts them, until it is stopped', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      final card = SimulatedCard(delay: Duration.zero);
      final log = _Log();
      late final BatchBurn batch;
      batch = BatchBurn(
        channel: card,
        log: log,
        keys: GpKeys.defaultTestKey().keys,
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
        onChanged: () {
          if (batch.done >= 4) batch.stop(); // four cards, then the operator stops
        },
      );
      await batch.run();

      expect(batch.done, 4);
      expect(batch.ok, 4, reason: batch.cards.map((c) => c.line).join('\n'));
      expect(batch.failed, 0);
      expect(batch.running, isFalse);
      expect(batch.stage, BatchStage.idle);
      // the cards are numbered from 1 and each says so
      expect([for (final c in batch.cards) c.number], [1, 2, 3, 4]);
      expect(batch.cards.first.line, startsWith('OK finished for 1'));
      expect(batch.cards.last.line, startsWith('OK finished for 4'));
      // and the log carries the same lines, so the run can be read back afterwards
      expect(log.lines.where((l) => l.contains('OK finished for')), hasLength(4));
      expect(log.lines.last, contains('4 burned, 0 failed'));
    });

    test('every card is a different card, with its own new card ID', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      final card = SimulatedCard(delay: Duration.zero);
      late final BatchBurn batch;
      batch = BatchBurn(
        channel: card,
        log: _Log(),
        keys: GpKeys.defaultTestKey().keys,
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
        onChanged: () {
          if (batch.done >= 3) batch.stop();
        },
      );
      await batch.run();
      final ids = [for (final c in batch.cards) Hex.compact(c.cardId)];
      expect(ids, hasLength(3));
      expect(ids.every((id) => id.length == 20), isTrue, reason: 'every card reports a 10-byte card ID: $ids');
      expect(ids.toSet(), hasLength(3), reason: 'each burn makes a new card ID, so no two are the same: $ids');
    });

    test('a wrong key set fails every card and the run gives up by itself', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      final card = SimulatedCard(delay: Duration.zero);
      final log = _Log();
      final wrong = Hex.parse('00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF');
      final batch = BatchBurn(
        channel: card,
        log: log,
        keys: GpKeys(enc: wrong, mac: wrong, dek: wrong),
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
      );
      await batch.run();
      expect(batch.ok, 0);
      expect(batch.failed, 3, reason: 'it stops after three in a row rather than spoiling a whole tray');
      expect(batch.running, isFalse);
      expect(batch.stopped, contains('3 cards in a row failed'));
      expect(batch.cards.first.line, startsWith('FAILED for 1'));
      expect(batch.cards.first.message, contains('did not prove it has the same keys'));
      expect(log.lines.any((l) => l.contains('Auto load stopped')), isTrue);
    });

    test('with stopAfterFailures 0 (as the app runs it) failures do not stop the run — it goes until stopped', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      final wrong = Hex.parse('00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF');
      late final BatchBurn batch;
      batch = BatchBurn(
        channel: SimulatedCard(delay: Duration.zero),
        log: _Log(),
        keys: GpKeys(enc: wrong, mac: wrong, dek: wrong),
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
        stopAfterFailures: 0, // the app passes 0
        onChanged: () {
          if (batch.done >= 6) batch.stop();
        },
      );
      await batch.run();
      expect(batch.failed, 6, reason: 'it kept going well past 3 failures');
      expect(batch.ok, 0);
      expect(batch.stopped, 'you stopped it', reason: 'it ended because it was stopped, not because it gave up');
    });

    test('blockers lists what to delete to force an install: the applet at the AID, the default-selected one, the package', () {
      final emg = Hex.parse('45 4D 47 30 30 30 30 30 30 30');
      final egas = Hex.parse('A0 00 00 00 03 45 47 41 53 00');
      final pkg = Hex.parse('45 4D 47 30 30 30 30 30 30');
      // the applet is at the instance AID (not default-selected), another applet holds default-selected, the package is there
      final contents = CardContents(
        const [],
        [GpEntry(emg, 0x07, 0x00), GpEntry(egas, 0x07, 0x04)],
        [GpEntry(pkg, 0x01, 0x00, kind: GpKind.package)],
      );
      final b = contents.blockers(pkg, instanceAid: emg, defaultSelected: true);
      expect(b.map((e) => Hex.of(e.$1)).toList(), [Hex.of(emg), Hex.of(egas), Hex.of(pkg)]);
      expect(b.map((e) => e.$2).toList(), [false, false, true], reason: 'an instance is deleted alone, a package with what came from it');
      // when the applet at the AID is itself the default-selected one, and no package on the card defines it, it is
      // deleted on its own, listed once
      final c2 = CardContents(const [], [GpEntry(emg, 0x07, 0x04)], const []);
      expect(c2.blockers(pkg, instanceAid: emg, defaultSelected: true).map((e) => Hex.of(e.$1)).toList(), [Hex.of(emg)]);
      // but when the applet is an instance of a package on the card, that PACKAGE is deleted (which takes the instance),
      // because a card refuses to delete a default-selected instance on its own (69 85 on the real card)
      final owned = CardContents(const [], [GpEntry(emg, 0x07, 0x04)], [GpEntry(pkg, 0x01, 0x00, modules: [emg], kind: GpKind.package)]);
      final ob = owned.blockers(pkg, instanceAid: emg, defaultSelected: true);
      expect(ob.map((e) => Hex.of(e.$1)).toList(), [Hex.of(pkg)], reason: 'delete the owning package, not the instance');
      expect(ob.single.$2, isTrue, reason: 'with what came from it');
      // with nothing in the way, nothing to delete
      expect(CardContents(const [], const [], const []).blockers(pkg, instanceAid: emg, defaultSelected: true), isEmpty);
    });

    test('Force burns over a card that already has the applet, without delete-first', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      final card = SimulatedCard(delay: Duration.zero); // the simulator comes with EMG installed and default-selected
      late final BatchBurn batch;
      batch = BatchBurn(
        channel: card,
        log: _Log(),
        keys: GpKeys.defaultTestKey().keys,
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
        deleteFirst: false, // without force this would be refused (the applet/package are already there)
        force: true,
        onChanged: () {
          if (batch.done >= 1) batch.stop();
        },
      );
      await batch.run();
      expect(batch.ok, 1, reason: batch.cards.map((c) => c.line).join('\n'));
      expect(batch.failed, 0, reason: 'force cleared the old applet and installed the new one');
    });

    test('stopping never leaves a card half written: the one being burned is finished first', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      final card = SimulatedCard(delay: Duration.zero);
      late final BatchBurn batch;
      batch = BatchBurn(
        channel: card,
        log: _Log(),
        keys: GpKeys.defaultTestKey().keys,
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
        onChanged: () {
          // stop the moment the first card starts burning
          if (batch.stage == BatchStage.burning) batch.stop();
        },
      );
      await batch.run();
      expect(batch.done, 1, reason: 'the card already on the reader is still finished');
      expect(batch.ok, 1, reason: batch.cards.map((c) => c.line).join('\n'));
      // the card really did get the applet
      await card.fieldReset();
      final r = ResponseApdu.fromRaw(await card.transmit(Hex.parse('00 A4 00 00 02 30 40')));
      expect(r.sw, 0x9000);
    });
  });

  group('on a reader that holds its connection, as a real one does', () {
    test('a card swapped on a real reader is noticed, and the next card is burned', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      final reader = _FakeReader(SimulatedCard(delay: Duration.zero));
      final log = _Log();
      late final BatchBurn batch;
      // the operator, following what the screen asks for: take the card off when told, put the next one on when told
      var swaps = 0;
      batch = BatchBurn(
        channel: reader,
        log: log,
        keys: GpKeys.defaultTestKey().keys,
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
        onChanged: () {
          if (batch.stage == BatchStage.waitingForRemoval && reader.cardOnReader) {
            reader.takeOff();
          } else if (batch.stage == BatchStage.waitingForCard && !reader.cardOnReader) {
            reader.putNextOn();
            swaps++;
          }
          if (batch.done >= 3) batch.stop();
        },
      );
      await batch.run();

      expect(swaps, greaterThanOrEqualTo(2), reason: 'the cards really were swapped');
      expect(batch.done, 3, reason: 'it must go on past the first card:\n${batch.cards.map((c) => c.line).join('\n')}');
      expect(batch.ok, 3, reason: batch.cards.map((c) => c.line).join('\n'));
      expect([for (final c in batch.cards) c.number], [1, 2, 3]);
      expect(log.lines.where((l) => l.contains('OK finished for')), hasLength(3));
    });

    test('it lets go of the reader to look, so a card still on it is not taken for a new one', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      final reader = _FakeReader(SimulatedCard(delay: Duration.zero));
      late final BatchBurn batch;
      // the card is never taken off. Every look at the reader must be a real one, and no second card may be counted.
      var looksWhileWaiting = 0;
      batch = BatchBurn(
        channel: reader,
        log: _Log(),
        keys: GpKeys.defaultTestKey().keys,
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
      );
      reader.onLook = () {
        if (batch.stage != BatchStage.waitingForRemoval) return;
        looksWhileWaiting++;
        if (looksWhileWaiting >= 5) batch.stop(); // we have seen enough: it really is asking again and again
      };
      await batch.run();
      expect(batch.done, 1, reason: 'the card never left, so no second card was counted');
      expect(batch.ok, 1);
      expect(looksWhileWaiting, greaterThanOrEqualTo(5),
          reason: 'each look must be a fresh connect, or a removal would never be seen');
    });
  });

  group('the Auto load report', () {
    /// A finished run, so the page can be built without a reader.
    Future<BatchBurn> runOf(int cards) async {
      final cap = await CapFile.read(_cap!);
      late final BatchBurn batch;
      batch = BatchBurn(
        channel: SimulatedCard(delay: Duration.zero),
        log: _Log(),
        keys: GpKeys.defaultTestKey().keys,
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
        onChanged: () {
          if (batch.done >= cards) batch.stop();
        },
      );
      await batch.run();
      return batch;
    }

    BatchReportInput inputFor(BatchBurn batch) => BatchReportInput(
          generatedAt: DateTime(2026, 10, 4, 17, 30),
          batch: batch,
          reader: 'Identive CLOUD 4700 F Contactless Reader 0',
          capName: 'electrical_electrometer_2026-10-01.cap',
          packageAid: '45 4D 47 30 30 30 30 30 30',
          instanceAid: '45 4D 47 30 30 30 30 30 30 30',
          defaultSelected: true,
          deleteFirst: true,
          startedAt: DateTime(2026, 10, 4, 17, 25),
        );

    test('says how many cards were burned and lists every chip ID, and nothing that changes', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final batch = await runOf(4);
      final html = buildBatchReport(inputFor(batch));

      expect(html, startsWith('<!doctype html>'));
      expect(html, contains('Auto load report'));
      expect(html, contains('color-scheme:dark'), reason: 'every page the app writes is dark');
      expect(html, contains('@media print'), reason: 'and readable on paper');
      // the count, in big letters
      expect(html, contains('${batch.ok} cards burned'));
      expect(html, contains('Cards burned'));
      // every card: its number and its chip ID, which is the one that does not change
      for (final c in batch.cards) {
        expect(html, contains(c.chipId), reason: 'card ${c.number} should be listed by its chip ID');
      }
      expect(html, contains('Chip ID (CPLC)'));
      // the numbers that change are deliberately not on the page: they would only mislead
      expect(html, isNot(contains('Card ID (GET UID 80 08)')));
      expect(html, isNot(contains('Reader UID')));
      for (final c in batch.cards) {
        expect(html, isNot(contains(Hex.of(c.cardId))), reason: 'the card ID changes at every install');
        expect(html, isNot(contains(Hex.of(c.nfcUid))), reason: 'the reader UID changes at every tap');
      }
      // and what they were all given
      expect(html, contains('electrical_electrometer_2026-10-01.cap'));
      expect(html, contains('45 4D 47 30 30 30 30 30 30 30'));
      expect(html, contains('Default selected'));
      expect(html, contains('Identive CLOUD 4700 F Contactless Reader 0'));
      // the keys are never written down
      expect(html.toLowerCase(), isNot(contains('key-enc')));
      expect(html, isNot(contains(Hex.of(GpKeys.defaultTestKey().keys.enc))));
    });

    test('a run with failures says so, and why, without claiming the cards were burned', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      final wrong = Hex.parse('00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF');
      final batch = BatchBurn(
        channel: SimulatedCard(delay: Duration.zero),
        log: _Log(),
        keys: GpKeys(enc: wrong, mac: wrong, dek: wrong),
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
      );
      await batch.run();
      final html = buildBatchReport(inputFor(batch));
      expect(html, contains('0 cards burned'));
      expect(html, contains('No card took the applet'));
      expect(html, contains('FAILED'));
      expect(html, contains('did not prove it has the same keys'), reason: 'the reason belongs in the report');
      expect(html, contains('3 cards in a row failed'), reason: 'and why the run ended');
    });

    test('a run on the simulator says so next to the count', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final batch = await runOf(2);
      final real = buildBatchReport(inputFor(batch));
      expect(real, isNot(contains('SIMULATED card')));
      final sim = buildBatchReport(BatchReportInput(
        generatedAt: DateTime(2026, 10, 4),
        batch: batch,
        reader: 'Simulated card',
        capName: 'x.cap',
        packageAid: 'A0',
        instanceAid: 'A0',
        defaultSelected: true,
        deleteFirst: true,
        simulated: true,
      ));
      expect(sim, contains('SIMULATED card'));
      expect(sim, contains('class="sim"'), reason: 'it goes beside the count, not buried in the setup');
    });

    test('the app writes the report at the end of a run, into Outputs_Files', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final state = AppState(simulator: SimulatedCard(delay: Duration.zero)); // writeFiles on, as in the app
      state.selected = SimulatedCard.key;
      await state.connect();
      state.gpUseTestKey();
      await state.gpOpenCap(_cap!);
      final applet = state.gpCap!.appletAids.first;
      state.addListener(() {
        if ((state.batch?.done ?? 0) >= 3) state.batch?.stop();
      });
      await state.startAutoBurn(instanceAid: applet, moduleAid: applet, defaultSelected: true);

      final path = state.batchReportPath;
      expect(path, isNotNull, reason: 'a finished run should leave a report');
      final file = File(path!);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      expect(file.existsSync(), isTrue);
      expect(file.parent.path, (await AppState.outputDir()).path);
      expect(file.uri.pathSegments.last, startsWith('auto_load_'));
      final html = file.readAsStringSync();
      expect(html, contains('Auto load report'));
      for (final c in state.batch!.cards) {
        expect(html, contains(c.chipId), reason: 'card ${c.number} should be in the file by its chip ID');
      }
      state.dispose();
    });
  });

  group('the chip ID, which does not change', () {
    /// The CPLC the real test card gave on 4 Oct 2026, read with `80 CA 9F 7F 00`.
    final realCplc = Hex.parse('9F 7F 2A 47 90 D3 21 47 00 00 00 00 00 31 60 45 87 28 40 65 25 '
        '00 00 00 00 00 00 00 00 14 70 6A 35 38 37 32 38 00 00 00 00 00 00 00 00');

    test('the real card\'s CPLC is taken apart into the fields it is made of', () {
      final chip = Cplc.parse(realCplc);
      expect(chip, isNotNull);
      expect(Hex.compact(chip!.icFabricator), '4790');
      expect(chip.fabricator, 'NXP');
      expect(Hex.compact(chip.icType), 'D321');
      expect(Hex.compact(chip.icSerial), '45872840');
      expect(Hex.compact(chip.icBatch), '6525');
      expect(chip.chipId, '458728406525', reason: 'serial and batch together name the chip');
      expect(chip.bytes, hasLength(Cplc.length));
      expect(chip.fields, hasLength(18));
      // the tag and its length are taken off, and the bytes without them read the same
      expect(Cplc.parse(Hex.sub(realCplc, 3, Cplc.length))!.chipId, chip.chipId);
    });

    test('anything that is not CPLC is refused rather than read as rubbish', () {
      expect(Cplc.parse(Uint8List(0)), isNull);
      expect(Cplc.parse(Hex.parse('9F 7F 2A 47 90')), isNull, reason: 'a tag with too few bytes after it');
      expect(Cplc.parse(Uint8List(Cplc.length - 1)), isNull);
    });

    test('the simulated card answers CPLC the way the real one does, and every card has its own', () async {
      final card = SimulatedCard(delay: Duration.zero);
      await card.connect();
      // the card manager has to be selected first, as on the real card
      final select = ResponseApdu.fromRaw(
          card.transmitNow(Hex.parse('00 A4 04 00 08 A0 00 00 01 51 00 00 00 00')));
      expect(select.sw, 0x9000);
      final r = ResponseApdu.fromRaw(card.transmitNow(Cplc.getData));
      expect(r.sw, 0x9000, reason: 'CPLC is answered outside any secure channel');
      final chip = Cplc.parse(r.data);
      expect(chip, isNotNull);
      expect(chip!.chipId, hasLength(12));
      expect(chip.fabricator, 'NXP');

      // the chip ID stays the same over power-ups, unlike the reader UID
      await card.fieldReset();
      card.transmitNow(Hex.parse('00 A4 04 00 08 A0 00 00 01 51 00 00 00 00'));
      expect(Cplc.parse(ResponseApdu.fromRaw(card.transmitNow(Cplc.getData)).data)!.chipId, chip.chipId);

      // a different card is a different chip
      card.insertNewCard();
      await card.connect();
      card.transmitNow(Hex.parse('00 A4 04 00 08 A0 00 00 01 51 00 00 00 00'));
      final other = Cplc.parse(ResponseApdu.fromRaw(card.transmitNow(Cplc.getData)).data)!;
      expect(other.chipId, isNot(chip.chipId));
    });

    test('a batch names every card by its chip, and the report leads with it', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      late final BatchBurn batch;
      batch = BatchBurn(
        channel: SimulatedCard(delay: Duration.zero),
        log: _Log(),
        keys: GpKeys.defaultTestKey().keys,
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
        onChanged: () {
          if (batch.done >= 3) batch.stop();
        },
      );
      await batch.run();
      expect(batch.ok, 3);
      final chips = [for (final c in batch.cards) c.chipId];
      expect(chips.every((id) => id.length == 12), isTrue, reason: 'every card was named by its chip: $chips');
      expect(chips.toSet(), hasLength(3), reason: 'and no two cards share one: $chips');
      expect(batch.cards.first.line, contains('chip ${chips.first}'));

      final html = buildBatchReport(BatchReportInput(
        generatedAt: DateTime(2026, 10, 4),
        batch: batch,
        reader: 'reader',
        capName: 'x.cap',
        packageAid: 'A0',
        instanceAid: 'A0',
        defaultSelected: true,
        deleteFirst: true,
      ));
      expect(html, contains('Chip ID (CPLC)'));
      expect(html, contains('The chip IDs on their own'));
      for (final id in chips) {
        expect(html, contains(id), reason: 'the report should carry chip $id');
      }
      expect(html, contains('burned into the card when it is made'), reason: 'it says which number to keep');
      expect(html, contains('IC serial number'), reason: 'and shows the chip fields in full');
    });

    test('the same chip burned twice is called out', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final cap = await CapFile.read(_cap!);
      // the operator lifts a card and puts the SAME one back, so the chip ID comes up twice
      final reader = _FakeReader(SimulatedCard(delay: Duration.zero));
      late final BatchBurn batch;
      batch = BatchBurn(
        channel: reader,
        log: _Log(),
        keys: GpKeys.defaultTestKey().keys,
        cap: cap,
        instanceAid: cap.appletAids.first,
        moduleAid: cap.appletAids.first,
        poll: Duration.zero,
        onChanged: () {
          if (batch.stage == BatchStage.waitingForRemoval && reader.cardOnReader) {
            reader.takeOff();
          } else if (batch.stage == BatchStage.waitingForCard && !reader.cardOnReader) {
            reader.cardOnReader = true; // the same card goes back on: inner is left as it is
          }
          if (batch.done >= 2) batch.stop();
        },
      );
      await batch.run();
      expect(batch.ok, 2);
      expect(batch.cards[0].chipId, batch.cards[1].chipId, reason: 'it was the same card both times');
      final html = buildBatchReport(BatchReportInput(
        generatedAt: DateTime(2026, 10, 4),
        batch: batch,
        reader: 'reader',
        capName: 'x.cap',
        packageAid: 'A0',
        instanceAid: 'A0',
        defaultSelected: true,
        deleteFirst: true,
      ));
      expect(html, contains('the same card was burned again'), reason: 'the repeat is called out');
      expect(html, contains('class="dupc dupc0"'), reason: 'the repeated chip ID is coloured');
      expect(html, contains('&#215;2'), reason: 'the table marks the chip as seen twice');
    });
  });

  group('Auto load in the app', () {
    test('startAutoBurn burns a tray, counts it, and lets the app go again', () async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final state = AppState(writeFiles: false, simulator: SimulatedCard(delay: Duration.zero));
      state.selected = SimulatedCard.key;
      await state.connect();
      state.gpUseTestKey();
      await state.gpOpenCap(_cap!);
      final applet = state.gpCap!.appletAids.first;

      // stop it once five cards are done, the way a person presses Stop
      state.addListener(() {
        if ((state.batch?.done ?? 0) >= 5) state.batch?.stop();
      });
      await state.startAutoBurn(instanceAid: applet, moduleAid: applet, defaultSelected: true);

      final batch = state.batch!;
      expect(batch.running, isFalse);
      expect(batch.done, greaterThanOrEqualTo(5));
      expect(batch.ok, batch.done, reason: batch.cards.map((c) => c.line).join('\n'));
      expect(batch.failed, 0);
      expect(state.busy, isFalse, reason: 'the run held busy, and gave it back at the end');
      expect(state.batchRunning, isFalse);
      // the lines are numbered the way the user asked: OK finished for 1, then 2 ...
      for (var i = 0; i < batch.done; i++) {
        expect(batch.cards[i].line, startsWith('OK finished for ${i + 1}'));
      }
      // the AID box follows what was burned, and the stale results are gone
      expect(Hex.of(state.appletAid), Hex.of(applet));
      expect(state.gpContents, isNull, reason: 'the card on the reader changed many times over');
      state.dispose();
    });

    testWidgets('the Burner page offers Auto load and asks before it starts', (tester) async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState(writeFiles: false);
      state.selected = SimulatedCard.key;
      await tester.pumpWidget(NfcTesterApp(state: state));
      await tester.runAsync(() => state.connect());
      state.setPage(Pages.burner);
      await tester.pump(const Duration(milliseconds: 400));

      Finder onPage(Finder f) => find.descendant(of: find.byType(BurnerPage), matching: f);
      Future<void> press(Finder f) async {
        state.messengerKey.currentState
          ?..clearSnackBars()
          ..removeCurrentSnackBar();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.ensureVisible(f);
        await tester.pump();
        await tester.tap(f);
        await tester.pump();
      }

      // auto load needs only the keys and a CAP: no open channel.
      // The CAP goes in through the page, as a person does it, so the page fills the instance AID box from it.
      state.gpUseTestKey();
      await tester.enterText(onPage(find.widgetWithText(TextField, 'CAP file')), _cap!);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 100 && state.gpCap == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.gpCap, isNotNull);
      expect(state.gpOpen, isFalse, reason: 'no channel was opened by hand');
      final aidBox = onPage(find.widgetWithText(TextField, 'Install as (instance AID)'));
      expect(tester.widget<TextField>(aidBox).controller!.text, isNotEmpty,
          reason: 'choosing the CAP fills the instance AID, which auto load needs');
      expect(tester.takeException(), isNull, reason: 'the burner page with a CAP chosen');

      // pressing it asks first, and says what every card will get
      await press(onPage(find.widgetWithText(FilledButton, 'Auto load')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('onto one card after another'), findsOneWidget);
      expect(find.textContaining('OK finished for 1'), findsOneWidget, reason: 'it says how the run reads');
      expect(find.textContaining('keeps going until you press'), findsOneWidget, reason: 'it runs until the user stops it');
      await press(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.batch, isNull, reason: 'cancelling starts nothing');
      expect(state.busy, isFalse);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });

    testWidgets('the panel lists every card, newest first, with the counts', (tester) async {
      if (_cap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState(writeFiles: false, simulator: SimulatedCard(delay: Duration.zero));
      state.selected = SimulatedCard.key;
      await tester.runAsync(() async {
        await state.connect();
        state.gpUseTestKey();
        await state.gpOpenCap(_cap!);
        final applet = state.gpCap!.appletAids.first;
        state.addListener(() {
          if ((state.batch?.done ?? 0) >= 3) state.batch?.stop();
        });
        await state.startAutoBurn(instanceAid: applet, moduleAid: applet, defaultSelected: true);
      });
      await tester.pumpWidget(NfcTesterApp(state: state));
      state.setPage(Pages.burner);
      await tester.pump(const Duration(milliseconds: 400));

      Finder onPage(Finder f) => find.descendant(of: find.byType(BurnerPage), matching: f);
      final batch = state.batch!;
      expect(batch.done, greaterThanOrEqualTo(3));
      expect(onPage(find.text('Auto load')), findsWidgets);
      expect(onPage(find.textContaining('Finished: ${batch.ok} burned')), findsOneWidget);
      expect(onPage(find.text('burned')), findsOneWidget);
      expect(onPage(find.text('failed')), findsOneWidget);
      // the newest card is the one on show: the list is turned round so you see the card you just burned
      expect(onPage(find.textContaining('OK finished for ${batch.done}')), findsOneWidget,
          reason: 'the newest card should be the first line');
      // the older ones are in the run itself, and scroll into view; the panel only builds the lines it shows
      expect([for (final c in batch.cards) c.number], [for (var i = 1; i <= batch.done; i++) i]);
      expect(batch.cards.every((c) => c.ok), isTrue);
      expect(tester.takeException(), isNull, reason: 'the burner page with a finished batch');

      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  });
}
