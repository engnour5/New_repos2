// The burner page on the simulated card, driven the way a person drives it: the buttons are pressed, the dialogs are
// answered and the CAP path is typed. And the cases where the card would refuse, which must be caught before anything
// is sent, because a refusal halfway leaves the card with the old package deleted or the new one without an applet.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/simulated_card.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/gp/gp_keys.dart';
import 'package:iphone_nfc_tester/main.dart';
import 'package:iphone_nfc_tester/state/app_state.dart';
import 'package:iphone_nfc_tester/ui/pages/burner_page.dart';

final _emgCap = [
  r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\gas_electrometer_javaApplet\Versions\electrical_electrometer_2026-10-01.cap',
  r'D:\Applet_Card_G2\gas_electrometer_javaApplet\bin\Debug\electrical_electrometer\javacard\electrical_electrometer.cap',
].where((p) => File(p).existsSync()).firstOrNull;

final _egasCap = [
  r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\PyApduTool_Release\EGAS_old_CAP(249_issue).cap',
  r'D:\Applet_Card_G2\gas_electrometer_javaApplet\Tool\PyApduTool_Release\EGAS.cap',
].where((p) => File(p).existsSync()).firstOrNull;

final _emgApplet = Hex.parse('45 4D 47 30 30 30 30 30 30 30');

/// The card-manager commands that change the card, as the log names them.
final _changing = RegExp(r'\[(DELETE|INSTALL|LOAD)');

int _changesIn(AppState state) => state.logEntries.where((e) => e.kind == LogKind.sent && _changing.hasMatch(e.text)).length;

/// The real Windows fonts, so text is measured as in the app and a layout check means something.
Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final file = File('C:\\Windows\\Fonts\\$f');
    if (file.existsSync()) loader.addFont(Future.value(ByteData.view(Uint8List.fromList(file.readAsBytesSync()).buffer)));
  }
  await loader.load();
}

Future<AppState> _connected() async {
  final state = AppState(writeFiles: false);
  state.selected = SimulatedCard.key;
  await state.connect();
  state.gpUseTestKey();
  await state.gpAuthenticate();
  expect(state.gpOpen, isTrue, reason: state.gpError ?? '');
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await _loadFont('Segoe UI', ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf', 'segoeuii.ttf']);
    await _loadFont('Consolas', ['consola.ttf', 'consolab.ttf']);
  });

  group('what the card would refuse is caught before anything is sent', () {
    test('another applet holds "Default selected"', () async {
      if (_egasCap == null) {
        markTestSkipped('No second CAP file on this PC.');
        return;
      }
      final state = await _connected();
      await state.gpOpenCap(_egasCap!);
      final egas = state.gpCap!;
      final sent = _changesIn(state);
      await state.gpLoadCap(instanceAid: egas.appletAids.first, moduleAid: egas.appletAids.first, defaultSelected: true);
      expect(state.gpError, contains('45 4D 47 30 30 30 30 30 30 30 already holds "Default selected"'));
      expect(state.gpError, contains('Nothing was sent to the card.'));
      expect(_changesIn(state), sent);
      expect(state.gpContents!.packages, hasLength(1));
      state.dispose();
    });

    test('the default applet comes from another package, and "delete first" would have deleted ours for nothing', () async {
      if (_emgCap == null || _egasCap == null) {
        markTestSkipped('Two CAP files are needed.');
        return;
      }
      final state = await _connected();
      // EGAS becomes the default applet, and the EMG package stays on the card with no applet
      await state.gpDelete(_emgApplet);
      await state.gpOpenCap(_egasCap!);
      await state.gpLoadCap(instanceAid: state.gpCap!.appletAids.first, moduleAid: state.gpCap!.appletAids.first, defaultSelected: true);
      expect(state.gpError, isNull);

      await state.gpOpenCap(_emgCap!);
      final sent = _changesIn(state);
      await state.gpLoadCap(instanceAid: _emgApplet, moduleAid: _emgApplet, defaultSelected: true);
      expect(state.gpError, contains('A0 00 00 00 03 45 47 41 53 00 already holds "Default selected"'));
      expect(_changesIn(state), sent, reason: 'nothing may be deleted when the load cannot go through anyway');
      expect(state.gpContents!.package(SimulatedCard.packageAid), isNotNull, reason: 'the EMG package must still be there');
      state.dispose();
    });

    test('the package is already there and "delete first" is off', () async {
      if (_emgCap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final state = await _connected();
      await state.gpOpenCap(_emgCap!);
      final sent = _changesIn(state);
      await state.gpLoadCap(instanceAid: _emgApplet, moduleAid: _emgApplet, defaultSelected: true, deleteFirst: false);
      expect(state.gpError, contains('already on the card'));
      expect(state.gpError, contains('Delete the package first'));
      expect(_changesIn(state), sent);
      state.dispose();
    });

    test('the instance AID is taken by an applet of another package', () async {
      if (_emgCap == null || _egasCap == null) {
        markTestSkipped('Two CAP files are needed.');
        return;
      }
      final state = await _connected();
      await state.gpOpenCap(_egasCap!);
      final egasApplet = state.gpCap!.appletAids.first;
      await state.gpLoadCap(instanceAid: egasApplet, moduleAid: egasApplet, defaultSelected: false);
      await state.gpOpenCap(_emgCap!);
      final sent = _changesIn(state);
      await state.gpLoadCap(instanceAid: egasApplet, moduleAid: _emgApplet, defaultSelected: false);
      expect(state.gpError, contains('An applet with the AID ${Hex.of(egasApplet)} is already on the card'));
      expect(_changesIn(state), sent);
      expect(state.gpContents!.package(SimulatedCard.packageAid), isNotNull);
      state.dispose();
    });

    test('when only the delete can tell, the message says the old package was deleted', () async {
      if (_emgCap == null || _egasCap == null) {
        markTestSkipped('Two CAP files are needed.');
        return;
      }
      final state = await _connected();
      // the default applet has an AID no package defines, so which package it came from cannot be told beforehand
      await state.gpDelete(_emgApplet);
      await state.gpOpenCap(_egasCap!);
      final custom = Hex.parse('F0 01 02 03 04');
      await state.gpLoadCap(instanceAid: custom, moduleAid: state.gpCap!.appletAids.first, defaultSelected: true);
      expect(state.gpError, isNull);
      await state.runCheck(); // a result that must be cleared, because the card changes below
      expect(state.checkRows, isNotEmpty);
      await state.gpAuthenticate();

      await state.gpOpenCap(_emgCap!);
      await state.gpLoadCap(instanceAid: _emgApplet, moduleAid: _emgApplet, defaultSelected: true);
      expect(state.gpError, contains('The old package 45 4D 47 30 30 30 30 30 30 was deleted, but nothing new was loaded'));
      expect(state.gpError, contains('F0 01 02 03 04 already holds "Default selected"'));
      expect(state.gpContents!.package(SimulatedCard.packageAid), isNull, reason: 'the list shows what is really there');
      expect(state.checkRows, isEmpty, reason: 'the card changed, so the old results go');
      state.dispose();
    });

    test('an install the card refuses leaves the list showing the package with no applet', () async {
      if (_emgCap == null) {
        markTestSkipped('No CAP file on this PC.');
        return;
      }
      final state = await _connected();
      await state.gpOpenCap(_emgCap!);
      // an applet the package does not define: the card takes the package, then refuses the install
      await state.gpLoadCap(instanceAid: _emgApplet, moduleAid: Hex.parse('45 4D 47 39 39 39'), defaultSelected: true);
      expect(state.gpError, contains('now on the card with no applet installed from it'));
      expect(state.gpContents!.package(SimulatedCard.packageAid), isNotNull);
      expect(state.gpContents!.applications, isEmpty);
      state.dispose();
    });
  });

  test('"Default test key" takes the keys from config.ini, and they open the simulated card', () async {
    final d = GpKeys.defaultTestKey();
    final state = AppState(writeFiles: false);
    state.selected = SimulatedCard.key;
    await state.connect();
    state.gpUseTestKey();
    // compared, never printed: these are the test card's real keys
    expect(Hex.same(Hex.parse(state.gpEncController.text), d.keys.enc), isTrue);
    expect(Hex.same(Hex.parse(state.gpMacController.text), d.keys.mac), isTrue);
    expect(Hex.same(Hex.parse(state.gpDekController.text), d.keys.dek), isTrue);
    expect(state.gpKeySource, d.file == null ? contains('factory key') : 'the default test key in ${d.file}');
    expect(state.gpKeyVersion, 0, reason: 'PyApduTool keeps no key version, so the card picks: "any"');
    await state.gpAuthenticate();
    expect(state.gpOpen, isTrue, reason: state.gpError ?? '');
    expect(state.gpContents!.applications.single.asText, 'EMG0000000');

    // "From a config.ini" with PyApduTool's file opens it just the same
    if (d.file != null) {
      state.gpEncController.clear();
      state.gpApplyKeys();
      expect(state.gpKeys, isNull);
      await state.gpReadKeyFile(d.file);
      await state.gpAuthenticate();
      expect(state.gpOpen, isTrue, reason: state.gpError ?? '');
    }
    state.dispose();
  });

  test('keys that are not the default test key do not open the simulated card, and the error says what to do', () async {
    final state = AppState(writeFiles: false);
    state.selected = SimulatedCard.key;
    await state.connect();
    for (final c in [state.gpEncController, state.gpMacController, state.gpDekController]) {
      c.text = '00 11 22 33 44 55 66 77 88 99 AA BB CC DD EE FF';
    }
    state.gpApplyKeys();
    await state.gpAuthenticate();
    expect(state.gpOpen, isFalse);
    expect(state.gpError, contains('The card did not prove it has the same keys'));
    expect(state.gpError, contains('click "Default test key"'));

    // and a key version the card does not have is named as such
    state.gpUseTestKey();
    state.gpSetKeyVersion(3);
    await state.gpAuthenticate();
    expect(state.gpError, contains('no key set with key version 3'));
    state.gpSetKeyVersion(1); // the test card's key version
    await state.gpAuthenticate();
    expect(state.gpOpen, isTrue, reason: state.gpError ?? '');
    state.dispose();
  });

  test('a path pasted in quotes, as Explorer copies it, opens the file', () async {
    if (_emgCap == null) {
      markTestSkipped('No CAP file on this PC.');
      return;
    }
    final state = AppState(writeFiles: false);
    await state.gpOpenCap('  "${_emgCap!}"  ');
    expect(state.gpError, isNull);
    expect(state.gpCap!.packageAid, SimulatedCard.packageAid);
    expect(state.gpCapPath, _emgCap);

    final dir = await Directory.systemTemp.createTemp('nfc_tester_keys');
    addTearDown(() => dir.delete(recursive: true));
    final ini = File('${dir.path}\\config.ini')
      ..writeAsStringSync('[ControlCenter]\nauthkey = ${'40' * 16}\ncmackey = ${'41' * 16}\ndekkey = ${'42' * 16}\n');
    await state.gpReadKeyFile('"${ini.path}"');
    expect(state.gpKeys, isNotNull, reason: state.gpError ?? '');
    state.dispose();
  });

  testWidgets('the burner page clicked through: open, load, select, delete, load again', (tester) async {
    final cap = _emgCap;
    if (cap == null) {
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

    // every page stays built behind the one shown, so look on this one only
    Finder onPage(Finder f) => find.descendant(of: find.byType(BurnerPage), matching: f);
    Future<void> waitFor(bool Function() done, String what) async {
      // the simulator's delays run on the test clock; a file is read from the disk for real
      for (var i = 0; i < 400 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue, reason: 'waiting for $what. ${state.gpError ?? ''}');
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> press(Finder f) async {
      // a snack bar must not take the click
      state.messengerKey.currentState
        ?..clearSnackBars()
        ..removeCurrentSnackBar();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(f);
      await tester.pump();
      await tester.tap(f);
      await tester.pump();
    }

    String box(String label) => tester.widget<TextField>(onPage(find.widgetWithText(TextField, label))).controller!.text;
    String snack() => tester.widgetList<Text>(find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .join(' ');

    // the card ID the applet had before it is burned again
    final idBefore = Hex.sub(state.simulator.transmitNow(Hex.parse('80 08 00 00 0A')), 0, 10);

    // 1. the keys, then the channel
    expect(onPage(find.text('Connect first')), findsNothing);
    await press(onPage(find.text('Default test key')));
    expect(Hex.same(Hex.parse(box('Key-ENC (auth)')), GpKeys.defaultTestKey().keys.enc), isTrue,
        reason: 'the box should hold the default test key'); // compared, never printed
    expect(onPage(find.textContaining('From the ')), findsOneWidget);
    await press(onPage(find.text('Open channel')));
    await waitFor(() => !state.busy && state.gpContents != null, 'the channel');
    expect(state.gpOpen, isTrue, reason: state.gpError ?? '');
    expect(onPage(find.text('Packages (1)')), findsOneWidget);
    expect(onPage(find.text('Applets (1)')), findsOneWidget);
    expect(onPage(find.textContaining('Secure channel open')), findsOneWidget);
    expect(onPage(find.textContaining('key version 1')), findsOneWidget);

    // 2. the CAP file, pasted in quotes and confirmed with Enter
    await tester.enterText(onPage(find.widgetWithText(TextField, 'CAP file')), '"$cap"');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await waitFor(() => state.gpCap != null, 'the CAP file');
    expect(box('CAP file'), cap, reason: 'the box shows the path without the quotes');
    expect(box('Install as (instance AID)'), Hex.of(_emgApplet));
    expect(onPage(find.text('45 4D 47 30 30 30 30 30 30')), findsWidgets); // the package AID
    expect(onPage(find.text('946 bytes in 4 blocks')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 3. load and install, confirmed in the dialog
    await press(onPage(find.text('Load and install')));
    expect(find.text('Load ${state.gpCap!.name} onto the card?'), findsOneWidget);
    expect(find.textContaining('it is deleted first'), findsOneWidget);
    await press(find.text('Load it'));
    await waitFor(() => !state.busy && state.gpLoadDone == 4, 'the load');
    expect(state.gpError, isNull);
    expect(snack(), contains('is loaded and installed as ${Hex.of(_emgApplet)}'));
    expect(onPage(find.text('Block 4 of 4')), findsOneWidget);
    expect(state.gpContents!.applications.single.isDefaultSelected, isTrue);

    // the applet is a new instance: a new card ID and a file of 00, as a real card gives
    await tester.runAsync(() => state.readCard(openReport: false));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.readResult!.ok, isTrue, reason: state.readResult!.message);
    expect(state.readResult!.image, everyElement(0));
    expect(state.cardId, hasLength(10));
    expect(Hex.same(state.cardId, idBefore), isFalse, reason: 'install() makes a new card ID');
    expect(state.gpOpen, isFalse, reason: 'the read tapped the card, which ends the channel');
    state.setPage(Pages.burner);
    await tester.pump(const Duration(milliseconds: 400));
    expect(onPage(find.text('Open the secure channel first.')), findsOneWidget);

    // 4. SELECT from the list, as an app would
    await press(onPage(find.byTooltip('SELECT this AID, the way an app does. It closes the card manager channel.')));
    await waitFor(() => !state.busy && snack().contains('answered'), 'the SELECT');
    expect(snack(), contains('${Hex.of(_emgApplet)} answered 90 00'));

    // 5. delete the applet, then the package, each confirmed
    await press(onPage(find.text('Open channel')));
    await waitFor(() => !state.busy && state.gpOpen, 'the channel again');
    await press(onPage(find.byTooltip('Delete it from the card')).at(1)); // packages come first, then applets
    expect(find.text('Delete this applet?'), findsOneWidget);
    await press(find.text('Delete it'));
    await waitFor(() => !state.busy && state.gpContents!.applications.isEmpty, 'deleting the applet');
    expect(onPage(find.text('Applets (0)')), findsOneWidget);
    expect(onPage(find.text('Packages (1)')), findsOneWidget);

    await press(onPage(find.byTooltip('Delete it from the card')).first);
    expect(find.text('Delete this package?'), findsOneWidget);
    expect(find.textContaining('Every applet installed from it goes too'), findsOneWidget);
    await press(find.text('Delete it'));
    await waitFor(() => !state.busy && state.gpContents!.packages.isEmpty, 'deleting the package');
    expect(onPage(find.text('Packages (0)')), findsOneWidget);
    expect(onPage(find.text('No package on the card.')), findsOneWidget);

    // 6. load again, this time not as the default applet
    await press(onPage(find.text('Default selected')));
    await press(onPage(find.text('Load and install')));
    expect(find.textContaining('as the default applet'), findsNothing);
    expect(find.textContaining('it is deleted first'), findsNothing, reason: 'there is nothing to delete now');
    await press(find.text('Load it'));
    await waitFor(() => !state.busy && state.gpContents!.applications.isNotEmpty, 'the second load');
    expect(state.gpError, isNull);
    expect(state.gpContents!.applications.single.isDefaultSelected, isFalse);

    // 7. with "delete first" off, the refusal comes before the dialog, and nothing is sent
    await press(onPage(find.text('Delete the package first if it is there')));
    expect(tester.widgetList<Checkbox>(onPage(find.byType(Checkbox))).map((c) => c.value), [false, false, false],
        reason: 'default selected, delete first, and force are all off now');
    final sent = _changesIn(state);
    await press(onPage(find.text('Load and install')));
    await tester.pump(const Duration(milliseconds: 600)); // the snack bar slides in
    expect(find.text('Load it'), findsNothing, reason: 'no dialog for a load the card would refuse');
    expect(snack(), contains('already on the card'));
    expect(_changesIn(state), sent);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
