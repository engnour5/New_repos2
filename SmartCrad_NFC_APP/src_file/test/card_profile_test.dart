// The Card profile makes the tool work with cards other than the EMG electrometer: it holds the AID(s), how to select
// the file, how to read and write it, and how big it is. EMG stays the default, so nothing here changes the EMG card.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/simulated_card.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/applet.dart';
import 'package:iphone_nfc_tester/core/card_profile.dart';
import 'package:iphone_nfc_tester/core/card_reader.dart';
import 'package:iphone_nfc_tester/core/card_writer.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/ios_rules.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/core/platform.dart';
import 'package:iphone_nfc_tester/core/session.dart';
import 'package:iphone_nfc_tester/state/app_state.dart';

class _QuietLog implements Logger {
  @override
  void section(String text) {}
  @override
  void info(String text) {}
  @override
  void warn(String text) {}
  @override
  void exchange(String label, Uint8List sent, ResponseApdu response, double ms) {}
  @override
  void blocked(String label, Uint8List typed, String reason) {}
}

Future<(SimulatedCard, PhoneSession)> _session() async {
  final card = SimulatedCard(delay: Duration.zero);
  await card.connect();
  return (card, PhoneSession(card, IosRules.parse(''), _QuietLog(), platform: PhonePlatform.android));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the profile itself', () {
    test('the EMG profile is the default and keeps the old EMG behaviour', () {
      const p = CardProfile.emg;
      expect(p.builtIn, isTrue);
      expect(p.aidHex, AppletAid.defaultHex);
      expect(p.fileSize, 32768);
      expect(p.lastOffset, 0x7FFF);
      expect(p.blockCount, 128);
      expect(p.hasSelectFile, isTrue);
      expect(p.hasIdCommand, isTrue);
      expect(p.selectFile, '00 A4 00 00 02 30 40');
      expect(p.idCommand, '80 08 00 00 0A');
      expect(p.problem, isNull);
    });

    test('READ and UPDATE commands are built from the offset and the profile bytes', () {
      const p = CardProfile.emg;
      expect(p.readCommand(0x1234, 16), '00 B0 12 34 10');
      expect(p.readCommand(0, 2), '00 B0 00 00 02');
      expect(p.readCommand(0x7FFF, 2), '00 B0 7F FF 02');
      expect(p.writeCommand(0x0010, Hex.parse('AB CD')), Hex.parse('00 D6 00 10 02 AB CD'));
      // a card that uses other classes/instructions gets other bytes
      final other = p.copyWith(readCla: 0x80, readIns: 0xB2, writeCla: 0x84, writeIns: 0xD7);
      expect(other.readCommand(0x0100, 8), '80 B2 01 00 08');
      expect(other.writeCommand(0x0100, Hex.parse('01')), Hex.parse('84 D7 01 00 01 01'));
    });

    test('a file-is-the-applet profile selects no EF and reads no card ID', () {
      const p = CardProfile.plainBinary;
      expect(p.hasSelectFile, isFalse);
      expect(p.hasIdCommand, isTrue); // the starting point still tries GET UID; it can be cleared
      final none = p.copyWith(idCommand: '');
      expect(none.hasIdCommand, isFalse);
      expect(none.problem, isNull);
    });

    test('a profile that cannot work says why', () {
      expect(const CardProfile(name: 'x', aidHex: '').problem, contains('at least one AID'));
      expect(const CardProfile(name: 'x', aidHex: 'ZZ').problem, contains('not hex'));
      expect(const CardProfile(name: 'x', aidHex: 'A0', fileSize: 8).problem, contains('between 16 and 65536'));
      expect(const CardProfile(name: 'x', aidHex: 'A0', fileSize: 70000).problem, contains('between 16 and 65536'));
      expect(const CardProfile(name: 'x', aidHex: 'A0', selectFile: '00 A4').problem, contains('full APDU'));
      expect(const CardProfile(name: 'x', aidHex: 'A0', idCommand: 'GG').problem, contains('not hex'));
    });

    test('a profile is saved and read back with every field kept', () {
      final p = CardProfile.emg.copyWith(name: 'Meter 4 KB', fileSize: 4096, selectFile: '00 A4 00 00 02 AA BB');
      final back = CardProfile.fromJson(p.toJson());
      expect(back.name, p.name);
      expect(back.aidHex, p.aidHex);
      expect(back.fileSize, 4096);
      expect(back.selectFile, '00 A4 00 00 02 AA BB');
      expect(back.idCommand, p.idCommand);
      expect(back.readIns, p.readIns);
      expect(back.writeIns, p.writeIns);
    });

    test('only custom profiles are written to the file; the built-in ones are always there', () {
      expect(CardProfile.encode(CardProfile.builtInProfiles), '[]');
      final custom = CardProfile.emg.copyWith(name: 'Mine', fileSize: 2048);
      final text = CardProfile.encode([...CardProfile.builtInProfiles, custom]);
      final decoded = CardProfile.decode(text);
      expect(decoded, hasLength(1));
      expect(decoded.single.name, 'Mine');
      expect(decoded.single.fileSize, 2048);
      // a damaged file is read as "no custom profiles", not a crash
      expect(CardProfile.decode('not json'), isEmpty);
    });

    test('fromJson fills in the EMG defaults for anything missing', () {
      final p = CardProfile.fromJson({'name': 'bare', 'aidHex': 'A0 00'});
      expect(p.fileSize, 32768);
      expect(p.readIns, 0xB0);
      expect(p.writeIns, 0xD6);
      expect(p.selectFile, '00 A4 00 00 02 30 40');
    });
  });

  group('the reader and writer follow the profile', () {
    test('with the default EMG profile the whole 32 KB is read', () async {
      final (_, s) = await _session();
      final r = await CardReader(s, _QuietLog(), profile: CardProfile.emg).run();
      expect(r.expected, 32768);
      expect(r.ok, isTrue, reason: r.message);
      expect(r.image, hasLength(32768));
    });

    test('a smaller profile reads only its own bytes and stops at its own end', () async {
      final (_, s) = await _session();
      final small = CardProfile.emg.copyWith(name: 'EMG first 4 KB', fileSize: 4096);
      final r = await CardReader(s, _QuietLog(), profile: small).run();
      expect(r.expected, 4096);
      expect(r.bytesRead, 4096, reason: 'it read exactly the profile size, not the whole card');
      expect(r.image, hasLength(4096));
      expect(r.blockCount, 16);
      // the EMG simulator really does have more than 4 KB, so the end check flags it
      expect(r.moreThanExpected, isTrue);
    });

    test('a write stays inside the profile file size', () async {
      final (card, s) = await _session();
      final small = CardProfile.emg.copyWith(name: 'EMG first 4 KB', fileSize: 4096);
      final text = Hex.parse('11 22 33 44');
      final r = await CardWriter(s, _QuietLog(), CardWriteRequest(0x0010, text, fileSize: 4096), profile: small).run();
      expect(r.ok, isTrue, reason: r.message);
      card.transmitNow(Hex.parse('00 A4 00 00 02 30 40'));
      final back = ResponseApdu.fromRaw(card.transmitNow(Hex.parse('00 B0 00 10 04'))).data;
      expect(back, text);
      // a write that would run past the profile's end is refused before anything is sent
      final tooFar = CardWriteRequest(0x0FF0, Uint8List(32), fileSize: 4096);
      expect(tooFar.problem, contains('0FFF'));
    });
  });

  group('the app keeps and switches profiles', () {
    test('EMG is the active profile and both built-ins are offered', () {
      final state = AppState(writeFiles: false);
      expect(state.cardProfile.name, CardProfile.emg.name);
      expect(state.profiles.map((p) => p.name), containsAll([CardProfile.emg.name, CardProfile.plainBinary.name]));
      state.dispose();
    });

    test('choosing a profile points the AID box at its applet(s)', () {
      final state = AppState(writeFiles: false);
      state.setCardProfile(CardProfile.plainBinary);
      expect(state.cardProfile.name, CardProfile.plainBinary.name);
      expect(state.aidController.text, CardProfile.plainBinary.aidHex);
      state.dispose();
    });

    test('a custom profile is added, becomes active, and can be removed', () async {
      final state = AppState(writeFiles: false);
      final mine = CardProfile.emg.copyWith(name: 'My meter', fileSize: 8192);
      await state.addProfile(mine);
      expect(state.profiles.any((p) => p.name == 'My meter'), isTrue);
      expect(state.cardProfile.name, 'My meter');
      expect(state.cardProfile.fileSize, 8192);

      await state.deleteProfile(state.profiles.firstWhere((p) => p.name == 'My meter'));
      expect(state.profiles.any((p) => p.name == 'My meter'), isFalse);
      expect(state.cardProfile.name, CardProfile.emg.name, reason: 'deleting the active profile falls back to EMG');
      state.dispose();
    });

    test('a profile that cannot work is not added', () async {
      final state = AppState(writeFiles: false);
      final before = state.profiles.length;
      await state.addProfile(const CardProfile(name: 'broken', aidHex: ''));
      expect(state.profiles.length, before);
      expect(state.cardProfile.name, CardProfile.emg.name);
      state.dispose();
    });

    test('the block editor refuses a range past the active profile size', () async {
      final state = AppState(writeFiles: false);
      state.selected = SimulatedCard.key;
      await state.connect();
      await state.addProfile(CardProfile.emg.copyWith(name: 'EMG first 4 KB', fileSize: 4096));
      // inside 4 KB reads
      expect(await state.readBlocks(0x0010, 32), hasLength(32));
      // past 4 KB is refused
      expect(await state.readBlocks(0x0FF0, 32), isNull, reason: '0x0FF0 + 32 runs past 0x0FFF');
      state.dispose();
    });
  });
}
