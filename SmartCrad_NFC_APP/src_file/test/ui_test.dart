// Opens every page, before and after real runs on the simulator, as iPhone and as Android, and fails on any layout
// error. The real Windows fonts are loaded, so text is measured as in the app.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/simulated_card.dart';
import 'package:iphone_nfc_tester/core/card_profile.dart';
import 'package:iphone_nfc_tester/core/card_test.dart';
import 'package:iphone_nfc_tester/core/guide.dart';
import 'package:iphone_nfc_tester/core/guide_html.dart';
import 'package:iphone_nfc_tester/ui/pages/home_page.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/core/production_report.dart';
import 'package:iphone_nfc_tester/core/platform.dart';
import 'package:iphone_nfc_tester/gp/gp_keys.dart';
import 'package:iphone_nfc_tester/main.dart';
import 'package:iphone_nfc_tester/state/app_state.dart';

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final file = File('C:\\Windows\\Fonts\\$f');
    if (file.existsSync()) {
      final bytes = file.readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    }
  }
  await loader.load();
}

void main() {
  final errors = <String>[];

  setUpAll(() async {
    await _loadFont('Segoe UI', ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf', 'segoeuii.ttf']);
    await _loadFont('Consolas', ['consola.ttf', 'consolab.ttf']);
  });

  Future<void> visitAllPages(WidgetTester tester, AppState state, String when) async {
    for (var p = 0; p < Pages.count; p++) {
      state.setPage(p);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull, reason: 'page ${p + 1} $when\n${errors.join('\n')}');
    }
  }

  Future<void> runEverything(WidgetTester tester, AppState state, String who) async {
    await tester.runAsync(() => state.runCheck());
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.verdictYes, isTrue, reason: '$who check');
    expect(tester.takeException(), isNull, reason: '$who check page after the check');

    final reads = state.quickCommands.where((q) => !q.writes).toList();
    await tester.runAsync(() async {
      for (final q in reads) {
        await state.sendCommand(q.hex);
      }
      await state.sendCommand('00 A4 04 00 05 A0 00 00 09 99');
    });
    state.useCommand('00 B0 7F 00 00');
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.consoleItems.length, greaterThanOrEqualTo(reads.length + 1));

    // the writing buttons are real UPDATE BINARY commands whose Lc matches their data, but this run does not send
    // them: a shared helper must not change what is on the card
    final writes = state.quickCommands.where((q) => q.writes).toList();
    expect(writes, isNotEmpty);
    for (final q in writes) {
      final apdu = Hex.parse(q.hex);
      expect(apdu[1], 0xD6, reason: '${q.label} should be UPDATE BINARY');
      expect(apdu.length, 5 + apdu[4], reason: '${q.label}: Lc ${apdu[4]} does not match the data it carries');
    }
    expect(state.commandHistory, isNotEmpty);
    expect(tester.takeException(), isNull, reason: '$who console after the commands');

    await tester.runAsync(() => state.readCard(openReport: false));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.readResult?.ok, isTrue, reason: '$who read card');
    expect(state.readResult!.bytesRead, 32768);
    expect(tester.takeException(), isNull, reason: '$who read page after the read');

    await tester.runAsync(() => state.runTest());
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.testRows.length, CardTest.expectedRows, reason: '$who full test rows');
    expect(state.cardSize, 32768);
    expect(tester.takeException(), isNull, reason: '$who test page after the test');
  }

  testWidgets('each phone keeps its own results: switching never shows the other phone\'s', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState(writeFiles: false);
    state.selected = SimulatedCard.key;
    await tester.pumpWidget(NfcTesterApp(state: state));
    await tester.runAsync(() => state.connect());
    // the first frame starts the cross-fade of the banner title, the second one ends it
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    // everything as an iPhone
    await tester.runAsync(() async {
      await state.runCheck();
      await state.sendCommand('00 A4 04 00 05 A0 00 00 09 99'); // blocked by iOS
      await state.readCard(openReport: false);
      await state.runTest();
    });
    state.setPage(Pages.check);
    await settle();
    expect(state.verdictYes, isTrue);
    expect(find.text('YES, with 1 warning  ·  iPhone'), findsOneWidget);
    expect(state.testRows.length, CardTest.expectedRows);

    // Android: nothing of the iPhone runs is shown
    state.setPlatform(PhonePlatform.android);
    await settle();
    expect(find.text('YES, with 1 warning  ·  iPhone'), findsNothing);
    expect(state.checkRows, isEmpty);
    expect(state.verdictYes, isNull);
    expect(state.consoleItems, isEmpty);
    expect(state.readResult, isNull);
    expect(state.testRows, isEmpty);
    expect(state.cardSize, isNull);
    expect(state.phoneTitle, 'Connected');
    expect(state.phoneDetail, contains('Android'));
    expect(tester.takeException(), isNull);

    await tester.runAsync(() => state.runCheck());
    state.setPage(Pages.check);
    await settle();
    expect(find.text('YES  ·  Android'), findsOneWidget);
    expect(state.phoneTitle, 'YES');

    // back to the iPhone: its own results come back; the Android check is kept for later
    state.setPlatform(PhonePlatform.iphone);
    await settle();
    expect(find.text('YES, with 1 warning  ·  iPhone'), findsOneWidget);
    expect(find.text('YES  ·  Android'), findsNothing);
    expect(state.checkPlatform, PhonePlatform.iphone);
    expect(state.testRows.length, CardTest.expectedRows);
    expect(state.cardSize, 32768);
    expect(state.readResult?.ok, isTrue);
    expect(state.consoleItems.any((i) => i.kind == ConsoleKind.notSent), isTrue);
    state.setPlatform(PhonePlatform.android);
    expect(state.verdictYes, isTrue);
    expect(state.checkPlatform, PhonePlatform.android);
    expect(state.testRows, isEmpty);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('the burner opens a channel, lists the card, deletes the package and loads it back', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState(writeFiles: false);
    state.selected = SimulatedCard.key;
    await tester.pumpWidget(NfcTesterApp(state: state));
    await tester.runAsync(() => state.connect());
    state.setPage(Pages.burner);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('On the card'), findsOneWidget);
    expect(find.text('Card manager keys'), findsOneWidget);
    expect(find.text('Burn a CAP file'), findsOneWidget);

    // the three key boxes are the whole setup: nothing else is needed to open a channel
    state.gpUseTestKey();
    await tester.pump(const Duration(milliseconds: 400));
    // the default test key (config.ini's): compared, never printed
    final testKey = GpKeys.defaultTestKey().keys;
    expect(Hex.same(Hex.parse(state.gpEncController.text), testKey.enc), isTrue);
    expect(Hex.same(Hex.parse(state.gpMacController.text), testKey.mac), isTrue);
    expect(state.gpKeys, isNotNull);
    expect(state.gpKeyProblem, isNull);

    // a half-typed key is caught in the box, before anything reaches the card
    state.gpMacController.text = '40 41 42';
    state.gpApplyKeys();
    expect(state.gpKeys, isNull);
    expect(state.gpKeyProblem, contains('Key-MAC'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'the burner page with a key box half typed');
    state.gpUseTestKey();

    await tester.runAsync(() => state.gpAuthenticate());
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.gpOpen, isTrue, reason: state.gpError ?? '');
    expect(state.gpContents!.packages, hasLength(1));
    expect(state.gpContents!.applications.single.asText, 'EMG0000000');
    expect(tester.takeException(), isNull, reason: 'the burner page with a card listed');
    expect(find.text('Packages (1)'), findsOneWidget);
    expect(find.text('Applets (1)'), findsOneWidget);

    // a check run before the card changes, so it can be shown to be cleared afterwards. It taps the card, and a tap
    // resets it, so the card-manager channel has to be opened again before anything can be deleted.
    await tester.runAsync(() => state.runCheck());
    expect(state.checkRows, isNotEmpty);
    expect(state.gpOpen, isFalse, reason: 'a tap resets the card, which ends the card-manager channel');
    await tester.runAsync(() => state.gpAuthenticate());
    expect(state.gpOpen, isTrue, reason: state.gpError ?? '');

    await tester.runAsync(() => state.gpDelete(SimulatedCard.packageAid));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.gpContents!.packages, isEmpty);
    expect(state.gpContents!.applications, isEmpty);
    expect(state.checkRows, isEmpty, reason: 'the card changed, so the old results must go');

    final cap = [
      r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\gas_electrometer_javaApplet\Versions\electrical_electrometer_2026-10-01.cap',
      r'D:\Applet_Card_G2\gas_electrometer_javaApplet\bin\Debug\electrical_electrometer\javacard\electrical_electrometer.cap',
    ].where((p) => File(p).existsSync()).firstOrNull;
    if (cap != null) {
      await tester.runAsync(() => state.gpOpenCap(cap));
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.gpCap!.appletAids, isNotEmpty);
      expect(tester.takeException(), isNull, reason: 'the burner page with a CAP file chosen');
      await tester.runAsync(() => state.gpLoadCap(
            instanceAid: state.gpCap!.appletAids.first,
            moduleAid: state.gpCap!.appletAids.first,
            defaultSelected: true,
          ));
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.gpError, isNull);
      expect(state.gpContents!.packages, hasLength(1));
      expect(state.gpContents!.applications.single.isDefaultSelected, isTrue);
      // the applet really works again
      await tester.runAsync(() => state.runCheck());
      expect(state.verdictYes, isTrue);
    }

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('the live log opens by itself while a test runs and shows what was sent and answered', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState(writeFiles: false);
    state.selected = SimulatedCard.key;
    await tester.pumpWidget(NfcTesterApp(state: state));
    await tester.runAsync(() => state.connect());
    await tester.pump(const Duration(milliseconds: 400));

    // closed while nothing is happening, but the strip itself is always there
    expect(state.logDockOpen, isFalse);
    expect(find.text('Live log'), findsOneWidget);

    // it opens by itself for the length of a run, whichever page you are on
    state.setPage(Pages.check);
    late bool openDuringRun;
    await tester.runAsync(() async {
      final running = state.runCheck();
      await Future<void>.delayed(const Duration(milliseconds: 1));
      openDuringRun = state.logDockOpen;
      await running;
    });
    await tester.pump(const Duration(milliseconds: 400));
    expect(openDuringRun, isTrue, reason: 'the live log should open while a run is going');
    expect(state.logDockOpen, isFalse, reason: 'and close again afterwards unless it is pinned');

    // what was sent and what came back are both in it
    expect(state.logEntries.any((e) => e.kind == LogKind.sent), isTrue);
    expect(state.logEntries.any((e) => e.kind == LogKind.received && e.sw == 0x9000), isTrue);

    // pinning keeps it open, and every page still lays out with it taking the space
    state.toggleLogDock();
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.logDockPinned, isTrue);
    expect(state.logDockOpen, isTrue);
    await visitAllPages(tester, state, 'with the live log pinned open');

    state.toggleLogDock();
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.logDockOpen, isFalse);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('the guide opens the page a feature belongs to when it is pressed', (tester) async {
    // tall enough that the first sections are on screen without scrolling
    tester.view.physicalSize = const Size(1440, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState(writeFiles: false);
    state.selected = SimulatedCard.key;
    await tester.pumpWidget(NfcTesterApp(state: state));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.page, Pages.home);

    // There is no side column any more, so a page with no tile could not be reached at all.
    final reachable = guideFeatures.map((f) => f.page).whereType<int>().toSet();
    for (var p = 1; p < Pages.count; p++) {
      expect(reachable, contains(p), reason: 'page $p has no tile on the home screen, so nothing can open it');
    }
    for (final f in guideFeatures) {
      if (f.page != null) expect(f.page, inInclusiveRange(0, Pages.count - 1), reason: f.name);
    }
    expect(guideFeatures.first.page, Pages.runAll, reason: 'the headline action should be the first tile');

    Finder onHome(String text) => find.descendant(of: find.byType(HomePage), matching: find.text(text));

    // the long guide text is not on this screen any more: it belongs to the web page the button writes
    expect(onHome('Page 1 - Check'), findsNothing);
    expect(onHome('Before you start'), findsNothing);
    expect(buildGuideHtml(), contains('Page 1 - Check'), reason: 'the guide itself must survive in the report');
    expect(buildGuideHtml(), contains('Before you start'));

    // pressing a tile opens its page
    await tester.tap(onHome('APDU console'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.page, Pages.console);

    state.setPage(Pages.home);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(onHome('Burner (card manager)'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.page, Pages.burner);

    // the two phone tiles lead to the same screen but set the phone up differently
    state.setPlatform(PhonePlatform.iphone);
    state.setPage(Pages.home);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(onHome('Android check'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.page, Pages.check);
    expect(state.platform, PhonePlatform.android);

    // and Home brings you back from anywhere
    await tester.tap(find.widgetWithText(FilledButton, 'Home'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.page, Pages.home);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('the Card profiles tile opens its page and switches the active card', (tester) async {
    tester.view.physicalSize = const Size(1440, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState(writeFiles: false);
    state.selected = SimulatedCard.key;
    await tester.pumpWidget(NfcTesterApp(state: state));
    await tester.pump(const Duration(milliseconds: 400));

    // EMG is the default active card, and there is a Home tile for the feature
    expect(state.cardProfile.name, CardProfile.emg.name);
    final tile = find.descendant(of: find.byType(HomePage), matching: find.text('Card profiles'));
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.pump();
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.page, Pages.profiles);
    expect(find.text('ACTIVE CARD'), findsOneWidget);

    // pick the other built-in and make it the active card
    await tester.tap(find.text(CardProfile.plainBinary.name).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Use this card'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.cardProfile.name, CardProfile.plainBinary.name);

    // a built-in is read-only: it offers Duplicate, not Save
    expect(find.widgetWithText(OutlinedButton, 'Duplicate'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save and use'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('Run all tests covers both phones, adds the production checks and makes one report', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState(writeFiles: false);
    state.selected = SimulatedCard.key;
    await tester.pumpWidget(NfcTesterApp(state: state));
    await tester.runAsync(() => state.connect());
    state.setPage(Pages.runAll);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Run all tests'), findsWidgets);

    await tester.runAsync(() => state.runAllTests());
    await tester.pump(const Duration(milliseconds: 400));
    final s = state.production!;

    // every phone ran every stage
    expect(s.platforms, hasLength(2));
    for (final p in s.platforms) {
      expect(p.checkYes, isTrue, reason: '${p.platform.short} check: ${p.checkVerdict}');
      expect(p.readOk, isTrue, reason: '${p.platform.short} read: ${p.read?.message}');
      expect(p.testRows, hasLength(CardTest.expectedRows), reason: '${p.platform.short} test rows');
      expect(p.testFailures, 0, reason: '${p.platform.short}: ${p.testRows.where((r) => r.result == 'FAIL').map((r) => r.id).join(',')}');
      expect(p.cardSize, 32768);
    }
    expect(s.cardSize, 32768);

    // the extra production checks ran and are in the stage list
    expect(state.productionRows, isNotEmpty);
    expect(s.stages.length, 6 + state.productionRows.length);
    final names = s.stages.map((x) => x.name).toList();
    expect(names, containsAll(['iPhone check', 'iPhone read card', 'iPhone card unit test', 'Android card unit test']));
    expect(names, contains('The card selects the applet by itself'));
    expect(names, contains('An app can select the applet by its AID'));

    // the simulator's AID starts with 4, so the verdict is "ready, with warnings" and never a failure
    expect(s.failures, 0, reason: s.stages.where((x) => x.result == 'FAIL').map((x) => '${x.name}: ${x.detail}').join('\n'));
    expect(s.ready, isTrue);
    expect(s.warnings, greaterThan(0));
    // this ran on the simulator, and the verdict has to say so before anyone reads "READY" as a card result
    expect(s.simulated, isTrue);
    expect(s.verdict, startsWith('This ran against the SIMULATED card'));
    expect(s.verdict, contains('READY, with'));

    // the platform the user had chosen is put back, and the verdict is on screen rather than the last run's page
    expect(state.platform, PhonePlatform.iphone);
    expect(state.page, Pages.runAll);
    expect(tester.takeException(), isNull, reason: 'the run-all page with results');

    // and it all goes into one report
    final html = buildProductionReport(ProductionReportInput(
      generatedAt: DateTime(2026, 10, 3),
      summary: s,
      reader: 'Simulated card',
      aidList: state.aidController.text,
      appletAid: Hex.of(state.appletAid),
      seconds: 12.3,
    ));
    expect(html, startsWith('<!doctype html>'));
    expect(html, contains('READY, WITH WARNINGS'));
    expect(html, contains('class="sim"')); // the simulator warning is next to the verdict, not buried in the setup
    expect(html, contains('Card readiness report'));
    expect(html, contains('color-scheme:dark'));
    expect(html, contains('The card selects the applet by itself'));
    expect(html, contains('iPhone')); // both phones have their own section
    expect(html, contains('Android'));
    expect(html, contains('C01'));

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('burning an applet with another AID makes every screen talk to that AID', (tester) async {
    final cap = [
      r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\gas_electrometer_javaApplet\Versions\electrical_electrometer_2026-10-01.cap',
      r'D:\Applet_Card_G2\gas_electrometer_javaApplet\bin\Debug\electrical_electrometer\javacard\electrical_electrometer.cap',
    ].where((p) => File(p).existsSync()).firstOrNull;
    if (cap == null) {
      markTestSkipped('No CAP file on this PC to load.');
      return;
    }
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState(writeFiles: false);
    state.selected = SimulatedCard.key;
    await tester.pumpWidget(NfcTesterApp(state: state));
    await tester.runAsync(() => state.connect());
    expect(Hex.of(state.appletAid), '45 4D 47 30 30 30 30 30 30 30');

    // burn the same package under a different instance AID, as a second EMG applet would be
    final other = Hex.parse('F0 11 22 33 44 55 66');
    state.gpUseTestKey();
    await tester.runAsync(() async {
      await state.gpAuthenticate();
      await state.gpOpenCap(cap);
      await state.gpLoadCap(
        instanceAid: other,
        moduleAid: state.gpCap!.appletAids.first,
        defaultSelected: true,
      );
    });
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.gpError, isNull);
    expect(state.gpContents!.applications.single.aidText, Hex.of(other));

    // the whole app now follows the applet that is actually on the card
    expect(Hex.of(state.appletAid), Hex.of(other), reason: 'the AID box should point at what was just installed');
    expect(state.quickCommands.first.hex, '00 A4 04 00 07 F0 11 22 33 44 55 66',
        reason: 'the quick SELECT must carry the new AID and its own length byte');

    await tester.runAsync(() => state.runCheck());
    expect(state.verdictYes, isTrue, reason: state.verdict);
    await tester.runAsync(() => state.readCard(openReport: false));
    expect(state.readResult?.ok, isTrue, reason: state.readResult?.message);
    await tester.runAsync(() => state.runTest());
    expect(state.testRows.firstWhere((r) => r.id == 'C01').result, 'PASS', reason: 'SELECT of the burned AID should work');
    expect(state.cardSize, 32768);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  for (final size in const [Size(1440, 900), Size(1100, 700)]) {
    testWidgets('all pages lay out at ${size.width.toInt()} x ${size.height.toInt()}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add(details.toString());
        previous?.call(details);
      };
      addTearDown(() => FlutterError.onError = previous);

      final state = AppState(writeFiles: false);
      state.selected = SimulatedCard.key;
      await tester.pumpWidget(NfcTesterApp(state: state));
      await visitAllPages(tester, state, 'when not connected');

      // nothing runs before Connect
      await tester.runAsync(() => state.runCheck());
      expect(state.checkRows, isEmpty);

      await tester.runAsync(() => state.connect());
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.connected, isTrue);
      await visitAllPages(tester, state, 'when connected');

      await runEverything(tester, state, 'iPhone');
      await visitAllPages(tester, state, 'after the iPhone runs');

      state.setPlatform(PhonePlatform.android);
      await tester.pump(const Duration(milliseconds: 400));
      await runEverything(tester, state, 'Android');
      await visitAllPages(tester, state, 'after the Android runs');

      state.toggleTheme();
      await tester.pump(const Duration(milliseconds: 400));
      await visitAllPages(tester, state, 'in the light theme');

      await tester.runAsync(() => state.disconnect());
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.connected, isFalse);
      await visitAllPages(tester, state, 'after Disconnect');

      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }
}
