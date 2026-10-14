// Write card on the simulated card: what is written is on the card and proven by reading it back, what was there is
// kept so it can be undone, and a write that cannot fit or cannot reach the card writes nothing. Then the same through
// the app and through the page, pressed the way a person would.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/card/card_channel.dart';
import 'package:iphone_nfc_tester/card/simulated_card.dart';
import 'package:iphone_nfc_tester/core/apdu.dart';
import 'package:iphone_nfc_tester/core/card_file.dart';
import 'package:iphone_nfc_tester/core/card_layout.dart';
import 'package:iphone_nfc_tester/core/card_reader.dart';
import 'package:iphone_nfc_tester/core/card_writer.dart';
import 'package:iphone_nfc_tester/core/errors.dart';
import 'package:iphone_nfc_tester/core/hex.dart';
import 'package:iphone_nfc_tester/core/ios_rules.dart';
import 'package:iphone_nfc_tester/core/log.dart';
import 'package:iphone_nfc_tester/core/platform.dart';
import 'package:iphone_nfc_tester/core/session.dart';
import 'package:iphone_nfc_tester/main.dart';
import 'package:iphone_nfc_tester/state/app_state.dart';
import 'package:iphone_nfc_tester/ui/pages/read_page.dart';

class _Log implements Logger {
  final lines = <String>[];

  /// Called after every exchange, so a test can step in halfway through a run.
  void Function(String label)? onExchange;

  @override
  void section(String text) => lines.add('=== $text');

  @override
  void info(String text) => lines.add(text);

  @override
  void warn(String text) => lines.add('! $text');

  @override
  void exchange(String label, Uint8List sent, ResponseApdu response, double ms) {
    lines.add('>> ${Hex.of(sent)} [$label] << ${response.swText}');
    onExchange?.call(label);
  }

  @override
  void blocked(String label, Uint8List typed, String reason) => lines.add('>> ${Hex.of(typed)} [$label] NOT SENT');
}

/// The simulated card, taken off the reader after [failAfter] commands.
class _TakenAway implements CardChannel {
  _TakenAway(this.inner, {required this.failAfter});

  final SimulatedCard inner;
  int failAfter;
  bool gone = false;

  @override
  String get name => inner.name;

  @override
  bool get isSimulated => true;

  @override
  Uint8List? get atr => inner.atr;

  @override
  Future<void> connect() => inner.connect();

  @override
  Future<void> fieldReset() async {
    if (gone) throw CardException('The card is not on the reader.');
    await inner.fieldReset();
  }

  @override
  Future<Uint8List> transmit(Uint8List apdu) async {
    if (gone || failAfter-- <= 0) {
      gone = true;
      throw CardException('The card is not on the reader.');
    }
    return inner.transmit(apdu);
  }

  @override
  Future<Uint8List?> getUid() => inner.getUid();

  @override
  Future<void> disconnect() => inner.disconnect();

  @override
  Future<void> dispose() => inner.dispose();
}

const _emgAid = '454D4730303030303030';

/// What the card holds at [offset], straight from the simulator.
Uint8List _cardBytes(SimulatedCard card, int offset, int length) {
  card.transmitNow(Hex.parse('00 A4 00 00 02 30 40'));
  final out = BytesBuilder();
  for (var pos = offset; pos < offset + length; pos += 256) {
    final n = min(256, offset + length - pos);
    out.add(ResponseApdu.fromRaw(card.transmitNow(Uint8List.fromList([0x00, 0xB0, pos >> 8, pos & 0xFF, n & 0xFF]))).data);
  }
  return out.toBytes();
}

Future<(SimulatedCard, PhoneSession, _Log)> _session({PhonePlatform platform = PhonePlatform.android, String aids = _emgAid}) async {
  final card = SimulatedCard(delay: Duration.zero);
  await card.connect();
  final log = _Log();
  return (card, PhoneSession(card, IosRules.parse(aids), log, platform: platform), log);
}

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final file = File('C:\\Windows\\Fonts\\$f');
    if (file.existsSync()) loader.addFont(Future.value(ByteData.view(Uint8List.fromList(file.readAsBytesSync()).buffer)));
  }
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await _loadFont('Segoe UI', ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf', 'segoeuii.ttf']);
    await _loadFont('Consolas', ['consola.ttf', 'consolab.ttf']);
  });

  final text = Uint8List.fromList('EMG WRITE TEST'.codeUnits);

  group('the writer on the simulated card', () {
    test('writes bytes as an Android app; the card holds them and reading back proves it', () async {
      final (card, s, _) = await _session();
      final before = _cardBytes(card, 0x10, text.length);
      final r = await CardWriter(s, _Log(), CardWriteRequest(0x10, text)).run();
      expect(r.error, isNull);
      expect(r.ok, isTrue, reason: r.message);
      expect(r.before, before, reason: 'what was there is kept for Undo');
      expect(r.bytesChanged, greaterThan(0));
      expect(r.partsWritten, 1);
      expect(r.message, startsWith('OK: the 14 bytes at 0010-001D are on the card'));
      expect(_cardBytes(card, 0x10, text.length), text);
      expect(r.cardId, hasLength(10));
    });

    test('as an iPhone app it goes through the AID list, and an AID list the card does not answer writes nothing', () async {
      final (card, s, _) = await _session(platform: PhonePlatform.iphone);
      final r = await CardWriter(s, _Log(), CardWriteRequest(0x10, text)).run();
      expect(r.ok, isTrue, reason: r.message);

      final (other, s2, _) = await _session(platform: PhonePlatform.iphone, aids: 'A0 00 00 00 01 02 03');
      final before = _cardBytes(other, 0x10, text.length);
      final r2 = await CardWriter(s2, _Log(), CardWriteRequest(0x10, text)).run();
      expect(r2.ok, isFalse);
      expect(r2.error, contains('the iPhone did not find the card'));
      expect(r2.error, contains('Nothing was written'));
      expect(r2.bytesSent, 0);
      expect(_cardBytes(other, 0x10, text.length), before);
      expect(card, isNot(same(other)));
    });

    test('parts that already hold the bytes are not written again', () async {
      final (_, s, _) = await _session();
      await CardWriter(s, _Log(), CardWriteRequest(0x10, text)).run();
      final again = await CardWriter(s, _Log(), CardWriteRequest(0x10, text)).run();
      expect(again.ok, isTrue);
      expect(again.partsWritten, 0);
      expect(again.partsSkipped, 1);
      expect(again.bytesSent, 0);
      expect(again.changedCard, isFalse);
      expect(again.message, contains('it held them already'));
      // and when skipping is off, they are written anyway
      final forced = await CardWriter(s, _Log(), CardWriteRequest(0x10, text), skipUnchanged: false).run();
      expect(forced.partsWritten, 1);
      expect(forced.ok, isTrue);
    });

    test('a write that ends at 7FFF reaches the last byte, which the applet keeps apart', () async {
      final (card, s, _) = await _session();
      final r = await CardWriter(s, _Log(), CardWriteRequest(0x7FFC, Hex.parse('11 22 33 44'))).run();
      expect(r.ok, isTrue, reason: r.message);
      expect(_cardBytes(card, 0x7FFC, 4), Hex.parse('11 22 33 44'));
    });

    test('the whole 32 KB from an image, in 240-byte parts, then read back the same by Read card', () async {
      final (card, s, log) = await _session();
      final image = Uint8List.fromList(List<int>.generate(CardReadResult.defaultSize, (i) => (i * 31 + 7) & 0xFF));
      final r = await CardWriter(s, log, CardWriteRequest(0, image, source: 'image')).run();
      expect(r.ok, isTrue, reason: r.message);
      expect(r.partsWritten, (CardReadResult.defaultSize / CardWriter.part).ceil());
      expect(log.lines.where((l) => l.startsWith('>> 00 D6')).every((l) => Hex.parse(l.substring(3, 17))[4] <= CardWriter.part), isTrue);
      final read = await CardReader(s, _Log()).run();
      expect(read.ok, isTrue);
      expect(read.image, image);
      expect(card.atr, isNotNull);
    });

    test('a write that does not fit, or has nothing in it, is refused before anything is sent', () async {
      final (_, s, log) = await _session();
      final r = await CardWriter(s, log, CardWriteRequest(0x7FF0, Uint8List(32))).run();
      expect(r.error, contains('would go past 7FFF'));
      expect(r.error, contains('Nothing was sent to the card'));
      expect(r.commands, 0);
      expect(log.lines.where((l) => l.startsWith('>>')), isEmpty);
      expect(CardWriteRequest(0, Uint8List(0)).problem, contains('nothing to write'));
      expect(CardWriteRequest(0x8000, Uint8List(1)).problem, contains('between 0000 and 7FFF'));
      expect(CardWriteRequest(0, Uint8List(CardReadResult.defaultSize)).problem, isNull);
    });

    test('a card with no applet to hold the file: SELECT EF 3040 fails and nothing is written', () async {
      final card = SimulatedCard(delay: Duration.zero);
      card.isd.applets.clear(); // as after the applet is deleted: the card manager answers
      await card.connect();
      final s = PhoneSession(card, IosRules.parse(''), _Log(), platform: PhonePlatform.android);
      final r = await CardWriter(s, _Log(), CardWriteRequest(0x10, text)).run();
      expect(r.error, contains('SELECT file (00 A4 00 00 02 30 40) answered'));
      expect(r.error, contains('Nothing was written'));
      expect(r.bytesSent, 0);
    });

    test('the card taken away halfway: the write says how far it got, and that part can be undone', () async {
      final inner = SimulatedCard(delay: Duration.zero);
      await inner.connect();
      final original = _cardBytes(inner, 0, 2048);
      await inner.fieldReset();
      final away = _TakenAway(inner, failAfter: 4 + 8 + 3); // tap selects, then reading 2 KB, then 3 parts
      final s = PhoneSession(away, IosRules.parse(''), _Log(), platform: PhonePlatform.android);
      final data = Uint8List(2048)..fillRange(0, 2048, 0xAB);
      final r = await CardWriter(s, _Log(), CardWriteRequest(0, data)).run();
      expect(r.ok, isFalse);
      expect(r.error, contains('could not be reached'));
      expect(r.done, greaterThan(0));
      expect(r.done, lessThan(2048));
      expect(r.before, original, reason: 'the old bytes were read before anything was written');
      expect(r.message, contains('${r.done} of 2048 bytes were done before it stopped'));

      // the card is back: write the old bytes over what was done, and it is as it was
      await inner.fieldReset();
      final s2 = PhoneSession(inner, IosRules.parse(''), _Log(), platform: PhonePlatform.android);
      final undo = await CardWriter(s2, _Log(), CardWriteRequest(0, Uint8List.sublistView(r.before!, 0, r.done)), expectCardId: r.cardId).run();
      expect(undo.ok, isTrue, reason: undo.message);
      expect(_cardBytes(inner, 0, 2048), original);
    });

    test('an undo goes only to the card the write was made on', () async {
      final (card, s, _) = await _session();
      final before = _cardBytes(card, 0x10, text.length);
      final r = await CardWriter(s, _Log(), CardWriteRequest(0x10, text), expectCardId: Hex.parse('01 02 03 04 05 06 07 08 09 0A')).run();
      expect(r.error, contains('not the card the write was made on'));
      expect(r.bytesSent, 0);
      expect(_cardBytes(card, 0x10, text.length), before);
    });

    test('an iPhone session that runs out halfway is tapped again, and the write goes on', () async {
      final (card, s, log) = await _session(platform: PhonePlatform.iphone);
      var aged = false;
      log.onExchange = (label) {
        // past 60 s right after the first part is written, as on a slow iPhone
        if (!aged && label.startsWith('Write card: UPDATE')) {
          aged = true;
          s.ageForTest(61);
        }
      };
      final data = Uint8List(1000)..fillRange(0, 1000, 0x5A);
      final r = await CardWriter(s, log, CardWriteRequest(0x100, data)).run();
      expect(aged, isTrue);
      expect(r.ok, isTrue, reason: r.message);
      expect(r.warnings.join(' '), contains('tapped again'));
      expect(_cardBytes(card, 0x100, 1000), data);
    });
  });

  group('card files: the hex text the Smart Card Utility uses, and .bin', () {
    // the real files that live next to card_utility_v15.exe
    const utilityFolder = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\Microsoft.VC120.MFC';

    test('one line of hex is read as bytes, and written back the same way', () {
      final f = CardFile.parse(Uint8List.fromList('454D4720434152440A'.codeUnits));
      expect(f.format, CardFileFormat.hexText);
      expect(f.data, Hex.parse('454D4720434152440A'));
      expect(CardFile.toHexText(f.data), '454D4720434152440A', reason: 'upper case, nothing between the bytes');
      // and what this app writes is read back by itself
      final image = Uint8List.fromList(List<int>.generate(512, (i) => i & 0xFF));
      final round = CardFile.parse(Uint8List.fromList(CardFile.toHexText(image).codeUnits));
      expect(round.data, image);
      expect(round.format, CardFileFormat.hexText);
    });

    test('spaces, line ends and lower case are all read', () {
      for (final text in ['45 4d 47', '45,4D:47', '45\r\n4D\r\n47', ' 45-4d-47 ']) {
        expect(CardFile.parse(Uint8List.fromList(text.codeUnits)).data, Hex.parse('454D47'), reason: text);
      }
    });

    test('bytes that cannot be hex text are taken as a binary file', () {
      final bin = Uint8List.fromList([0x00, 0xFF, 0x45, 0x4D, 0x47, 0x80]);
      final f = CardFile.parse(bin);
      expect(f.format, CardFileFormat.binary);
      expect(f.data, bin);
      // a .bin of nothing but 00 bytes is binary too, not the text "00"
      expect(CardFile.parse(Uint8List(300)).format, CardFileFormat.binary);
    });

    test('the name does not decide: hex text called .bin is still read as hex text', () {
      // a real case: a 32 KB card saved as hex and named nnnn.bin. Going by the name it would be 65536 raw bytes,
      // twice what the card holds, and the write would be refused for nothing.
      final image = Uint8List.fromList(List<int>.generate(CardReadResult.defaultSize, (i) => (i * 7) & 0xFF));
      final asText = Uint8List.fromList(CardFile.toHexText(image).codeUnits);
      expect(asText.length, CardReadResult.defaultSize * 2);
      final f = CardFile.parse(asText, name: 'nnnn.bin');
      expect(f.format, CardFileFormat.hexText);
      expect(f.data, image);
      expect(CardWriteRequest(0, f.data).problem, isNull, reason: 'it fits the card, read the right way');
      // and the same bytes as a real .bin of that size would not fit, which is the answer the user should get
      expect(CardWriteRequest(0, asText).problem, contains('past 7FFF'));
    });

    test('an odd number of hex digits is refused, and so is an empty file', () {
      expect(() => CardFile.parse(Uint8List.fromList('454D4'.codeUnits), name: 'card.txt'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('odd number'))));
      expect(() => CardFile.parse(Uint8List(0)), throwsFormatException);
    });

    test('the real card files of the Smart Card Utility are read', () {
      final folder = Directory(utilityFolder);
      if (!folder.existsSync()) {
        markTestSkipped('The Smart Card Utility folder is not on this PC.');
        return;
      }
      final files = folder.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.txt')).toList();
      if (files.isEmpty) {
        markTestSkipped('No card .txt file to read.');
        return;
      }
      for (final f in files) {
        final card = CardFile.parse(f.readAsBytesSync(), name: f.path);
        expect(card.format, CardFileFormat.hexText, reason: f.path);
        expect(card.length * 2, f.lengthSync(), reason: '${f.path}: two hex digits per byte, nothing else in the file');
        // and it can be written back byte for byte
        expect(CardFile.toHexText(card.data).toUpperCase(), f.readAsStringSync().trim().toUpperCase(), reason: f.path);
      }
    });

    test('a real *_RFID_Card_*.txt goes to the card through the app, and comes back as the same hex text', () async {
      final file = Directory(utilityFolder).existsSync()
          ? Directory(utilityFolder)
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().contains('rfid_card') && f.path.toLowerCase().endsWith('.txt'))
              .firstOrNull
          : null;
      if (file == null) {
        markTestSkipped('No *_RFID_Card_*.txt on this PC.');
        return;
      }
      final card = CardFile.parse(file.readAsBytesSync(), name: file.path);
      expect(card.format, CardFileFormat.hexText);

      final state = AppState(writeFiles: false);
      state.selected = SimulatedCard.key;
      await state.connect();
      await state.writeCard(CardWriteRequest(0, card.data, source: file.uri.pathSegments.last));
      expect(state.writeResult!.ok, isTrue, reason: state.writeResult!.message);

      // read the card back and keep the part the file covers: it is the file again, byte for byte
      await state.readCard(openReport: false);
      expect(state.readResult!.ok, isTrue, reason: state.readResult!.message);
      final back = Uint8List.sublistView(state.readResult!.image, 0, card.length);
      expect(back, card.data);
      expect(CardFile.toHexText(back), file.readAsStringSync().trim().toUpperCase(),
          reason: 'what "Save .txt" writes is the file the utility gave us');
      state.dispose();
    });

    test('a whole card as hex text is written to the card and reads back the same', () async {
      final (card, s, _) = await _session();
      final image = Uint8List.fromList(List<int>.generate(CardReadResult.defaultSize, (i) => (i * 13 + 5) & 0xFF));
      final asText = CardFile.toHexText(image);
      expect(asText.length, CardReadResult.defaultSize * 2);
      final fromFile = CardFile.parse(Uint8List.fromList(asText.codeUnits));
      final r = await CardWriter(s, _Log(), CardWriteRequest(0, fromFile.data, source: 'card.txt')).run();
      expect(r.ok, isTrue, reason: r.message);
      expect(_cardBytes(card, 0, CardReadResult.defaultSize), image);
    });
  });

  group('what a card says about itself, and what a firmware card file holds', () {
    const vango = r'D:\ANSI_Projects\FW\svn\Vango_project\Versions';

    List<File> cardFiles() {
      final dir = Directory(vango);
      if (!dir.existsSync()) return const [];
      return dir.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.txt')).toList();
    }

    test('the identity block is read off a real meter card', () {
      final files = cardFiles();
      if (files.isEmpty) {
        markTestSkipped('The Vango card archive is not on this PC.');
        return;
      }
      var checked = 0;
      for (final f in files) {
        final Uint8List bytes;
        try {
          bytes = CardFile.parse(f.readAsBytesSync(), name: f.path).data;
        } on FormatException {
          continue;
        }
        final c = CardContent(bytes);
        if (!c.looksValid) continue;
        checked++;
        // every sample carries the same format version, and a company made of plain text
        expect(c.formatVersion, CardContent.knownFormat, reason: f.path);
        expect(c.knownLayout, isTrue, reason: f.path);
        expect(c.companyId, isNotEmpty, reason: f.path);
        expect(RegExp(r'^[ -~]+$').hasMatch(c.companyId), isTrue, reason: '${f.path}: ${c.companyId}');
        expect(c.cardId, hasLength(10), reason: f.path);
        expect(c.summary, contains(c.companyId), reason: f.path);
      }
      expect(checked, greaterThanOrEqualTo(5), reason: 'the archive should hold several meter cards');
    });

    test('a card of 00, and a freshly burned applet, have no identity block', () {
      expect(CardContent(Uint8List(CardReadResult.defaultSize)).looksValid, isFalse);
      expect(CardContent(Uint8List(CardReadResult.defaultSize)).summary, contains('No meter identity block'));
      // a card ID at 0000 and nothing else is not an identity block either
      final justAnId = Uint8List(CardReadResult.defaultSize)..setRange(0, 10, Hex.parse('45 4D 47 30 30 30 30 30 30 30'));
      expect(CardContent(justAnId).looksValid, isFalse);
    });

    test('the fields are where the layout says, and do not overlap', () {
      var next = 0;
      for (final f in CardContent.fields) {
        expect(f.offset, next, reason: '${f.name} should follow the field before it');
        next = f.offset + f.length;
      }
      expect(next, 0x40, reason: 'the identity block is the first 64 bytes');
      // a known card: the fields land on the right text
      final image = Uint8List(CardReadResult.defaultSize);
      image.setRange(0x0A, 0x10, '1.0.13'.codeUnits);
      image.setRange(0x10, 0x17, 'EMG-SEE'.codeUnits);
      image.setRange(0x1A, 0x20, 'FW.295'.codeUnits);
      image.setRange(0x20, 0x2B, 'North Delta'.codeUnits);
      final c = CardContent(image);
      expect(c.looksValid, isTrue);
      expect(c.companyId, 'EMG-SEE');
      expect(c.firmwareVersion, 'FW.295');
      expect(c.region, 'North Delta');
    });

    test('a firmware card file is read frame by frame, and the firmware comes out whole', () {
      final files = cardFiles().where((f) => f.path.toLowerCase().contains('rfid_card')).toList();
      if (files.isEmpty) {
        markTestSkipped('No firmware card files on this PC.');
        return;
      }
      var cards = 0;
      for (final f in files) {
        final Uint8List bytes;
        try {
          bytes = CardFile.parse(f.readAsBytesSync(), name: f.path).data;
        } on FormatException {
          continue;
        }
        final frames = CardFrames.parse(bytes);
        if (frames == null) continue;
        cards++;
        expect(frames.frames, isNotEmpty);
        expect(frames.version, isNotEmpty, reason: f.path);
        // the frames of one card run in order, and all name the same version and total
        var last = -1;
        for (final fr in frames.frames) {
          expect(fr.seq, greaterThan(last), reason: '${f.path}: frames should be in order');
          expect(fr.total, frames.total, reason: f.path);
          expect(fr.version, frames.version, reason: f.path);
          expect(fr.seq, lessThan(fr.total), reason: f.path);
          last = fr.seq;
        }
        expect(frames.firmware.length, frames.frames.fold<int>(0, (n, fr) => n + fr.firmware.length));
        expect(frames.firmware.length, frames.frames.length * 256, reason: '256 firmware bytes per frame');
        expect(frames.summary, contains(frames.version));
      }
      expect(cards, greaterThanOrEqualTo(10), reason: 'the archive should hold many firmware cards');
    });

    test('every frame of every real card file passes its CRC-8', () {
      final files = cardFiles();
      if (files.isEmpty) {
        markTestSkipped('The Vango card archive is not on this PC.');
        return;
      }
      var frames = 0, bad = 0;
      final badFiles = <String>[];
      for (final f in files) {
        final Uint8List bytes;
        try {
          bytes = CardFile.parse(f.readAsBytesSync(), name: f.path).data;
        } on FormatException {
          continue;
        }
        final parsed = CardFrames.parse(bytes);
        if (parsed == null) continue;
        frames += parsed.frames.length;
        if (!parsed.allChecksPass) {
          bad += parsed.damaged.length;
          badFiles.add('${f.uri.pathSegments.last} (${parsed.damaged.length})');
        }
      }
      expect(frames, greaterThan(4000), reason: 'the archive should hold thousands of frames');
      // 435-delta.txt is a working file whose frames are damaged: its versions read as "40240" and "000000".
      expect(badFiles.where((n) => !n.startsWith('435-delta')), isEmpty,
          reason: 'only the known damaged working file may fail: $badFiles');
      expect(bad, lessThan(3), reason: 'all but a frame or two of the damaged file should pass');
    });

    test('calc_crc is CRC-8 poly 0x31 init 0x00, and both the frame CRC and the inner firmware CRC check out', () {
      // the empty message: the start value (0) comes straight back out
      expect(CardFrames.calcCrc(Uint8List(0)), 0x00);
      expect(CardFrames.crcPolynomial, 0x31);
      // one byte, worked out by hand with the same polynomial from init 0
      var crc = 0x00 ^ 0xFF;
      for (var i = 0; i < 8; i++) {
        crc = crc & 0x80 != 0 ? ((crc << 1) ^ 0x31) & 0xFF : (crc << 1) & 0xFF;
      }
      expect(CardFrames.calcCrc(Uint8List.fromList([0xFF])), crc);
      // and a frame built from its own fields gives both bytes the card file carries
      final files = cardFiles().where((f) => f.path.toLowerCase().contains('rfid_card'));
      for (final f in files.take(4)) {
        final parsed = CardFrames.parse(CardFile.parse(f.readAsBytesSync()).data);
        if (parsed == null) continue;
        for (final fr in parsed.frames.take(20)) {
          expect(fr.check, fr.wantedCheck, reason: '${f.path} frame ${fr.seq} outer CRC');
          expect(fr.innerCheck, fr.wantedInner, reason: '${f.path} frame ${fr.seq} inner CRC');
          expect(fr.firmware, hasLength(256));
          expect(fr.checkOk, isTrue);
        }
      }
    });

    test('a frame with a byte changed is caught by its CRC', () {
      final files = cardFiles().where((f) => f.path.toLowerCase().contains('rfid_card')).toList();
      if (files.isEmpty) {
        markTestSkipped('No firmware card file on this PC.');
        return;
      }
      final bytes = CardFile.parse(files.first.readAsBytesSync()).data;
      final good = CardFrames.parse(bytes)!;
      expect(good.allChecksPass, isTrue);
      expect(good.summary, contains('Every frame passes its CRC'));
      // flip one bit in the first frame's payload: that frame, and only that frame, should fail
      final hurt = Uint8List.fromList(bytes);
      hurt[good.frames.first.start + CardFrames.headerFields + 5] ^= 0x01;
      final after = CardFrames.parse(hurt)!;
      expect(after.allChecksPass, isFalse);
      expect(after.damaged, hasLength(1));
      expect(after.damaged.single.seq, good.frames.first.seq);
      expect(after.summary, contains('the file is damaged'));
    });

    test('the chained whole-image CRC matches the file_crc the last frame carries', () {
      final dir = Directory('$vango\\Single_Phase\\Egypt\\SOGWAVE_EGYPT_BOARD_LOCAL_1PH_433');
      if (!dir.existsSync()) {
        markTestSkipped('The 433 card set is not on this PC.');
        return;
      }
      final pages = <int, Uint8List>{};
      for (final f in dir.listSync().whereType<File>()) {
        if (!RegExp(r'^SOGWAVE.*_RFID_Card_\d+\.txt$', caseSensitive: false).hasMatch(f.uri.pathSegments.last)) continue;
        final frames = CardFrames.parse(CardFile.parse(f.readAsBytesSync()).data);
        if (frames == null) continue;
        for (final fr in frames.frames) {
          pages[fr.seq] = fr.firmware;
        }
      }
      final total = pages.keys.reduce((a, b) => a > b ? a : b) + 1;
      final last = pages[total - 1]!;
      // the last frame's tail: file_crc at firmware[250], type at 251, length at 252..255
      final fileCrc = last[250];
      final fileLength = last[252] | (last[253] << 8) | (last[254] << 16) | (last[255] << 24);
      final ordered = [for (var i = 0; i < total; i++) pages[i]!];
      expect(CardFrames.imageCrc(ordered, lastPageLength: fileLength % 256), fileCrc,
          reason: 'the chained image CRC should equal the stored file_crc');
    });

    test('a full card set rebuilds firmware that starts with an ARM vector table', () {
      final dir = Directory('$vango\\Single_Phase\\Egypt\\SOGWAVE_EGYPT_BOARD_LOCAL_1PH_433');
      if (!dir.existsSync()) {
        markTestSkipped('The 433 card set is not on this PC.');
        return;
      }
      // the file NAME, not the path: the folder is called SOGWAVE_... too, and holds a bootloader set as well
      final set = dir
          .listSync()
          .whereType<File>()
          .where((f) => RegExp(r'^SOGWAVE.*_RFID_Card_\d+\.txt$', caseSensitive: false).hasMatch(f.uri.pathSegments.last))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (set.isEmpty) {
        markTestSkipped('No card set to rebuild.');
        return;
      }
      final bySeq = <int, Uint8List>{};
      String? version;
      int? total;
      for (final f in set) {
        final frames = CardFrames.parse(CardFile.parse(f.readAsBytesSync()).data);
        expect(frames, isNotNull, reason: f.path);
        version ??= frames!.version;
        total ??= frames!.total;
        expect(frames!.version, version, reason: 'every card of a set names the same version');
        expect(frames.total, total, reason: 'every card of a set names the same total');
        for (final fr in frames.frames) {
          bySeq[fr.seq] = fr.payload;
        }
      }
      // the cards of a set carry different pieces: together they are most of the firmware
      expect(bySeq.length, greaterThan(300), reason: 'the set should hold hundreds of frames');
      final firmware = Hex.concat([for (final k in bySeq.keys.toList()..sort()) bySeq[k]!]);
      expect(firmware.length, greaterThan(80000));
      // Cortex-M: the first word is a stack pointer in SRAM, the second a Thumb reset handler
      final sp = firmware[0] | (firmware[1] << 8) | (firmware[2] << 16) | (firmware[3] << 24);
      final reset = firmware[4] | (firmware[5] << 8) | (firmware[6] << 16) | (firmware[7] << 24);
      expect(sp & 0xFFF00000, 0x20000000, reason: 'the stack pointer should point into SRAM, got ${h4(sp >> 16)}');
      expect(reset.isOdd, isTrue, reason: 'a Thumb entry point is odd');
      expect(reset, lessThan(0x00100000), reason: 'the reset handler should be in flash');
    });

    test('a hand-built complete card parses, rebuilds byte-for-byte, and re-CRCs when the firmware changes', () {
      // a full card made by hand: a 256-byte header with two auth blocks, one frame of 256 firmware + its tail
      const fileLen = 200; // the last page holds 200 real firmware bytes, then the tail at 250..255
      final page = Uint8List(256);
      for (var i = 0; i < fileLen; i++) {
        page[i] = (i * 7 + 3) & 0xFF;
      }
      page[251] = 2; // bootloader
      page[252] = fileLen & 0xFF; // length, little-endian
      page[250] = CardFrames.imageCrc([page], lastPageLength: fileLen); // the whole-image CRC

      final header = <int>[0x02, 0x0C, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, ...'v.101'.codeUnits, 0x00, 0x00];
      final payload = <int>[...page, CardFrames.calcCrc(page)]; // 256 firmware + inner CRC
      final frame = <int>[...header, ...payload, ...CardFrames.terminator];
      frame.add(CardFrames.calcCrc(Hex.sub(Uint8List.fromList(frame), 1, 275))); // frame CRC, STX skipped

      final cardHeader = Uint8List(256);
      cardHeader.setRange(0x40, 0x50, Hex.parse('A1 A2 A3 A4 A5 A6 A7 A8 A9 AA AB AC AD AE AF B0')); // "auth" block 0x40
      cardHeader.setRange(0xD0, 0xE0, Hex.parse('D1 D2 D3 D4 D5 D6 D7 D8 D9 DA DB DC DD DE DF E0')); // block 0xD0
      final file = Uint8List.fromList([...cardHeader, ...frame, ...List.filled(51, 0)]); // + trailing padding

      final frames = CardFrames.parse(file)!;
      expect(frames.frames, hasLength(1));
      expect(frames.complete, isTrue);
      expect(frames.allChecksPass, isTrue, reason: frames.summary);
      expect(frames.hasFileMeta, isTrue);
      expect(frames.fileType, 2);
      expect(frames.fileTypeText, 'bootloader');
      expect(frames.fileLengthBytes, fileLen);
      expect(frames.fileCrc, page[250]);

      // rebuilding with nothing changed reproduces the card exactly
      expect(frames.rebuildWith(), file, reason: 'identity rebuild is byte-for-byte');
      // and writing the same firmware back is also byte-for-byte (exercises the tail CRC path)
      expect(frames.rebuildWith(firmware: frames.firmware), file);

      // change one firmware byte: the card re-CRCs, the header and padding do not move, the new byte is on the card
      final edited = Uint8List.fromList(frames.firmware);
      edited[5] ^= 0xFF;
      final rebuilt = frames.rebuildWith(firmware: edited);
      expect(rebuilt, isNot(file));
      expect(rebuilt.length, file.length);
      final reparsed = CardFrames.parse(rebuilt)!;
      expect(reparsed.allChecksPass, isTrue, reason: 'every per-frame CRC is right again');
      expect(reparsed.firmware[5], edited[5], reason: 'the change is on the card');
      expect(reparsed.fileCrc, CardFrames.imageCrc([reparsed.firmware], lastPageLength: fileLen),
          reason: 'the whole-image CRC was recomputed for the new firmware');
      expect(reparsed.fileCrc, isNot(frames.fileCrc), reason: 'and it changed');
      expect(Hex.sub(rebuilt, 0, 256), cardHeader, reason: 'the header and its auth blocks are kept exactly');
      expect(Hex.sub(rebuilt, rebuilt.length - 51, 51), Uint8List(51), reason: 'the padding is kept');
    });

    test('every real firmware card rebuilds byte-for-byte, and a complete one takes new firmware', () {
      final files = cardFiles().where((f) => f.path.toLowerCase().contains('rfid_card')).toList();
      if (files.isEmpty) {
        markTestSkipped('No firmware card files on this PC.');
        return;
      }
      var identity = 0;
      for (final f in files) {
        final Uint8List bytes;
        try {
          bytes = CardFile.parse(f.readAsBytesSync(), name: f.path).data;
        } on FormatException {
          continue;
        }
        final frames = CardFrames.parse(bytes);
        if (frames == null || !frames.allChecksPass) continue; // skip the one known-damaged working file
        // a genuine card rebuilds to the same bytes it came from
        expect(frames.rebuildWith(), bytes, reason: '${f.path}: identity rebuild');
        identity++;
        if (frames.complete) {
          // writing the same firmware back reproduces it exactly (the tail CRC path), and a change re-CRCs cleanly
          expect(frames.rebuildWith(firmware: frames.firmware), bytes, reason: '${f.path}: same firmware reproduces it');
          final edited = Uint8List.fromList(frames.firmware);
          edited[10] ^= 0xFF;
          final reparsed = CardFrames.parse(frames.rebuildWith(firmware: edited))!;
          expect(reparsed.allChecksPass, isTrue, reason: '${f.path}: the rebuilt card passes every CRC');
          expect(reparsed.firmware[10], edited[10]);
          expect(Hex.sub(frames.rebuildWith(firmware: edited), 0, frames.headerBytes), Hex.sub(bytes, 0, frames.headerBytes),
              reason: '${f.path}: the header is kept');
        }
      }
      expect(identity, greaterThan(10), reason: 'the archive should hold many rebuildable cards');
      // (complete single-card files may or may not be in the archive; the hand-built test covers that path for sure)
    });

    test('a hand-built card SET rebuilds byte-for-byte and takes new firmware of the same size', () {
      const total = 4;
      Uint8List frame(int seq, Uint8List page) {
        final body = <int>[0x02, 0x0C, 0x01, 0x00, seq & 0xFF, seq >> 8, total & 0xFF, total >> 8, ...'2.900'.codeUnits, 0, 0,
          ...page, CardFrames.calcCrc(page), ...CardFrames.terminator];
        body.add(CardFrames.calcCrc(Hex.sub(Uint8List.fromList(body), 1, 275)));
        return Uint8List.fromList(body);
      }

      // the finished meter image: 4 pages, real length 900, carrying its file tail in the last page
      final fw = Uint8List(total * 256);
      for (var i = 0; i < 900; i++) {
        fw[i] = (i * 5 + 1) & 0xFF;
      }
      fw[3 * 256 + 251] = 1; // delta
      fw[3 * 256 + 252] = 900 & 0xFF;
      fw[3 * 256 + 253] = (900 >> 8) & 0xFF;
      fw[3 * 256 + 250] = CardFrames.imageCrc([for (var i = 0; i < total; i++) Hex.sub(fw, i * 256, 256)], lastPageLength: 900 % 256);

      Uint8List card(Uint8List authD0, List<int> seqs) {
        final h = Uint8List(256);
        h.setRange(0x40, 0x50, Hex.parse('A1 A2 A3 A4 A5 A6 A7 A8 A9 AA AB AC AD AE AF B0'));
        h.setRange(0xD0, 0xE0, authD0);
        final b = <int>[...h];
        for (final s in seqs) {
          b.addAll(frame(s, Hex.sub(fw, s * 256, 256)));
        }
        b.addAll(List.filled(40, 0)); // padding
        return Uint8List.fromList(b);
      }

      final card1 = card(Hex.parse('11 11 11 11 11 11 11 11 11 11 11 11 11 11 11 11'), [0, 1]);
      final card2 = card(Hex.parse('22 22 22 22 22 22 22 22 22 22 22 22 22 22 22 22'), [2, 3]);
      final c1 = CardFrames.parse(card1)!, c2 = CardFrames.parse(card2)!;

      // the set rebuilds to the same bytes, in either input order (it sorts by frame)
      expect(CardFrames.rebuildSet([c1, c2]), [card1, card2]);
      expect(CardFrames.rebuildSet([c2, c1]), [card1, card2]);

      // a new build of the same size: flip a firmware byte, rebuild the set
      final fw2 = Uint8List.fromList(fw)..[300] ^= 0xFF;
      final made = CardFrames.rebuildSet([c1, c2], firmware: fw2);
      final r1 = CardFrames.parse(made[0])!, r2 = CardFrames.parse(made[1])!;
      expect(r1.allChecksPass && r2.allChecksPass, isTrue, reason: 'every frame CRC is right on the new set');
      expect(Hex.sub(made[0], 0, 256), Hex.sub(card1, 0, 256), reason: 'card 1 header and auth blocks are kept');
      expect(Hex.sub(made[1], 0, 256), Hex.sub(card2, 0, 256), reason: 'card 2 header and auth blocks are kept');
      final reFw = Hex.concat([for (final f in [...r1.frames, ...r2.frames]) f.firmware]);
      expect(reFw[300], fw2[300], reason: 'the changed firmware byte is on the cards');
      // firmware of the wrong size, or a broken set, is refused
      expect(() => CardFrames.rebuildSet([c1, c2], firmware: Uint8List(total * 256 - 1)), throwsArgumentError);
      expect(() => CardFrames.rebuildSet([c1]), throwsArgumentError); // frames 2-3 missing
    });

    test('the EM120 526 set regenerates byte-for-byte from its firmware', () {
      const d = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\SmartCrad_NFC_APP';
      final bin = File('$d\\SOGWAVE_EM120_AMER_1PH_526.bin');
      final files = [for (var i = 1; i <= 4; i++) File('$d\\SOGWAVE_EM120_AMER_1PH_526_RFID_Card_$i.txt')];
      if (!bin.existsSync() || files.any((f) => !f.existsSync())) {
        markTestSkipped('The EM120 526 sample is not on this PC.');
        return;
      }
      final fw = bin.readAsBytesSync();
      final cards = [for (final f in files) CardFrames.parse(CardFile.parse(f.readAsBytesSync()).data)!];
      final made = CardFrames.rebuildSet(cards, firmware: fw);
      for (var i = 0; i < 4; i++) {
        expect(made[i], cards[i].data, reason: 'EM120 Card ${i + 1} regenerates byte-for-byte from the firmware');
      }
    });

    test('buildSet makes a valid set from a product recipe alone, for any firmware size', () {
      const p = FirmwareProduct(
        name: 'test',
        auth40: 'AABBCCDDEEFF00112233445566778899',
        d0ByCount: {1: '11223344556677889900AABBCCDDEEFF', 2: 'FFEEDDCCBBAA00998877665544332211'},
        framesPerCard: 2,
      );
      final fw = Uint8List(3 * 256); // 3 pages -> cards of 2 and 1 frames
      for (var i = 0; i < fw.length; i++) {
        fw[i] = (i * 7 + 1) & 0xFF;
      }
      final made = CardFrames.buildSet(fw, p, '1.000');
      expect(made, hasLength(2));
      final c0 = CardFrames.parse(made[0])!, c1 = CardFrames.parse(made[1])!;
      expect(c0.frames.length, 2);
      expect(c1.frames.length, 1);
      expect(c0.total, 3);
      expect(c0.allChecksPass && c1.allChecksPass, isTrue, reason: 'every frame CRC is right');
      expect(Hex.compact(Hex.sub(made[0], 0x40, 16)), p.auth40, reason: '0x40 is placed');
      expect(Hex.compact(Hex.sub(made[0], 0xD0, 16)), p.d0ByCount[2], reason: '0xD0 for a 2-frame card');
      expect(Hex.compact(Hex.sub(made[1], 0xD0, 16)), p.d0ByCount[1], reason: '0xD0 for a 1-frame card');
      expect(made[0].length % 255, 0, reason: 'each card is padded to a multiple of 255');
      final re = Hex.concat([for (final f in [...c0.frames, ...c1.frames]) f.firmware]);
      expect(re, fw, reason: 'the firmware reassembles byte-for-byte');
      // a non-page firmware and a bad version are refused
      expect(() => CardFrames.buildSet(Uint8List(100), p, '1.000'), throwsArgumentError);
      expect(() => CardFrames.buildSet(fw, p, 'too long'), throwsArgumentError);
      // a frame count the recipe has no 0xD0 for is STILL built: 0xD0 is a reserved block the meter ignores, left zero
      final noD0 = CardFrames.buildSet(Uint8List(256), const FirmwareProduct(name: 'x', auth40: '00112233445566778899AABBCCDDEEFF', d0ByCount: {}), '1.000');
      expect(CardFrames.parse(noD0[0])!.allChecksPass, isTrue, reason: 'frames are valid even with no recipe 0xD0');
      expect(Hex.compact(Hex.sub(noD0[0], 0xD0, 16)), '00000000000000000000000000000000', reason: 'unknown-count 0xD0 is left zero');
    });

    test('the EM120 526 set builds from the firmware ALONE (no template) byte-for-byte', () {
      const d = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\SmartCrad_NFC_APP';
      final bin = File('$d\\SOGWAVE_EM120_AMER_1PH_526.bin');
      final files = [for (var i = 1; i <= 4; i++) File('$d\\SOGWAVE_EM120_AMER_1PH_526_RFID_Card_$i.txt')];
      if (!bin.existsSync() || files.any((f) => !f.existsSync())) {
        markTestSkipped('The EM120 526 sample is not on this PC.');
        return;
      }
      final made = CardFrames.buildSet(bin.readAsBytesSync(), FirmwareProduct.sogwave1Ph, '4.526');
      expect(made, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(made[i], CardFile.parse(files[i].readAsBytesSync()).data,
            reason: 'EM120 Card ${i + 1} built from the firmware alone matches the utility byte-for-byte');
      }
    });

    test('the GPRS 1PH 553 set (a 90-frame last card, version b.553) builds from the firmware ALONE byte-for-byte', () {
      const d = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\SmartCrad_NFC_APP';
      final bin = File('$d\\SOGWAVE_GPRS_LOCAL_1PH_553.bin');
      final files = [for (var i = 1; i <= 4; i++) File('$d\\SOGWAVE_GPRS_LOCAL_1PH_553_RFID_Card_$i.txt')];
      if (!bin.existsSync() || files.any((f) => !f.existsSync())) {
        markTestSkipped('The GPRS 553 sample is not on this PC.');
        return;
      }
      final made = CardFrames.buildSet(bin.readAsBytesSync(), FirmwareProduct.sogwave1Ph, 'b.553');
      expect(made, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(made[i], CardFile.parse(files[i].readAsBytesSync()).data,
            reason: 'GPRS Card ${i + 1} built from the firmware alone matches the utility byte-for-byte');
      }
    });

    test('the GPRS 1PH 521 set (a 54-frame last card the recipe has no 0xD0 for) still builds from the firmware ALONE', () {
      const d = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\SmartCrad_NFC_APP';
      final bin = File('$d\\SOGWAVE_GPRS_LOCAL_1PH_521.bin');
      if (!bin.existsSync()) {
        markTestSkipped('The GPRS 521 sample is not on this PC.');
        return;
      }
      final made = CardFrames.buildSet(bin.readAsBytesSync(), FirmwareProduct.sogwave1Ph, 'b.521');
      expect(made, hasLength(4), reason: '405 frames split 117/117/117/54');
      final parsed = [for (final m in made) CardFrames.parse(m)!];
      expect([for (final c in parsed) c.frames.length], [117, 117, 117, 54]);
      expect(parsed.every((c) => c.allChecksPass), isTrue, reason: 'every frame CRC (inner + frame) is right on all 4 cards');
      expect(parsed.first.total, 405, reason: 'the set is a 405-frame image');
      expect(parsed.first.firstSeq, 0);
      expect(parsed.last.lastSeq, 404, reason: 'the four cards together cover frames 0..404');
      expect(parsed.last.version, 'b.521');
      // the three 117-frame cards carry the utility 0xD0; the 54-frame card has no recipe 0xD0, so it is left zero
      expect(Hex.compact(Hex.sub(made[0], 0xD0, 16)), FirmwareProduct.sogwave1Ph.d0ByCount[117]);
      expect(Hex.compact(Hex.sub(made[3], 0xD0, 16)), '00000000000000000000000000000000');
      // 0x40 (the auth block the meter reads) is the family constant on every card
      expect(made.every((m) => Hex.compact(Hex.sub(m, 0x40, 16)) == FirmwareProduct.sogwave1Ph.auth40), isTrue);
    });

    test('the GPRS 1PH 525 set (a 61-frame last card) builds byte-for-byte, incl the 0xD0 the utility uses', () {
      const d = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\SmartCrad_NFC_APP';
      final bin = File('$d\\SOGWAVE_GPRS_LOCAL_1PH_525.bin');
      final files = [for (var i = 1; i <= 4; i++) File('$d\\SOGWAVE_GPRS_LOCAL_1PH_525_RFID_Card_$i.txt')];
      if (!bin.existsSync() || files.any((f) => !f.existsSync())) {
        markTestSkipped('The GPRS 525 sample is not on this PC.');
        return;
      }
      final made = CardFrames.buildSet(bin.readAsBytesSync(), FirmwareProduct.sogwave1Ph, 'b.525');
      expect(made, hasLength(4), reason: '412 frames split 117/117/117/61');
      for (var i = 0; i < 4; i++) {
        expect(made[i], CardFile.parse(files[i].readAsBytesSync()).data,
            reason: 'GPRS 525 Card ${i + 1} (the 4th is the 61-frame last card) matches the utility byte-for-byte');
      }
    });

    test('the EM122 4G GPRS AMER 520 set builds byte-for-byte (56-frame last card, version g.520)', () {
      const d = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\SmartCrad_NFC_APP';
      const base = 'SOGWAVE_EM122_4G_GPRS_RS_4800_AMER_1PH_520';
      final bin = File('$d\\$base.bin');
      final files = [for (var i = 1; i <= 4; i++) File('$d\\${base}_RFID_Card_$i.txt')];
      if (!bin.existsSync() || files.any((f) => !f.existsSync())) {
        markTestSkipped('The EM122 520 sample is not on this PC.');
        return;
      }
      final made = CardFrames.buildSet(bin.readAsBytesSync(), FirmwareProduct.sogwave1Ph, 'g.520');
      expect(made, hasLength(4), reason: '407 frames split 117/117/117/56');
      for (var i = 0; i < 4; i++) {
        expect(made[i], CardFile.parse(files[i].readAsBytesSync()).data,
            reason: 'EM122 520 Card ${i + 1} matches the utility byte-for-byte');
      }
    });

    test('version prefix: 4G is matched before GPRS, so the EM122 4G AMER board is g. not b.', () {
      String prefixFor(String name) {
        final upper = name.toUpperCase();
        for (final e in FirmwareProduct.sogwave1Ph.versionPrefixes.entries) {
          if (upper.contains(e.key)) return e.value;
        }
        return FirmwareProduct.sogwave1Ph.defaultVersionPrefix;
      }
      expect(prefixFor('SOGWAVE_EM122_4G_GPRS_RS_4800_AMER_1PH_520'), 'g.', reason: '4G board, not plain GPRS');
      expect(prefixFor('SOGWAVE_GPRS_LOCAL_1PH_525'), 'b.');
      expect(prefixFor('SOGWAVE_EM120_AMER_1PH_526'), '4.');
      expect(prefixFor('SOGWAVE_EGYPT_BOARD_LOCAL_1PH_529'), '2.');
    });

    test('learnD0 reads the utility 0xD0 off a reference card, filters by family, and merges (no hand entry)', () {
      // a set built with a known 0xD0 is read back exactly by learnD0
      const p = FirmwareProduct(
          name: 't', auth40: '112233445566778899AABBCCDDEEFF00',
          d0ByCount: {2: 'A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1'}, framesPerCard: 2);
      final made = CardFrames.buildSet(Uint8List(2 * 256), p, '1.000'); // one card of 2 frames
      expect(CardFrames.learnD0(made, auth40: p.auth40)[2], 'A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1');
      // a different family's 0x40 is not learned from it
      expect(CardFrames.learnD0(made, auth40: '00000000000000000000000000000000'), isEmpty);
      // withExtraD0 adds the learned value and keeps the built-in ones
      final merged = FirmwareProduct.sogwave1Ph.withExtraD0({73: 'ABABABABABABABABABABABABABABABAB'});
      expect(merged.d0ByCount[73], 'ABABABABABABABABABABABABABABABAB');
      expect(merged.d0ByCount[117], FirmwareProduct.sogwave1Ph.d0ByCount[117]);
    });

    test('learnD0 recovers the utility 0xD0 for every card of the real GPRS 525 set', () {
      const d = r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\SmartCrad_NFC_APP';
      final files = [for (var i = 1; i <= 4; i++) File('$d\\SOGWAVE_GPRS_LOCAL_1PH_525_RFID_Card_$i.txt')];
      if (files.any((f) => !f.existsSync())) {
        markTestSkipped('The GPRS 525 sample is not on this PC.');
        return;
      }
      final learned = CardFrames.learnD0(
          [for (final f in files) CardFile.parse(f.readAsBytesSync()).data], auth40: FirmwareProduct.sogwave1Ph.auth40);
      expect(learned[61], 'DBF058CA4F49258B599ED6859EABAAAA', reason: 'the 61-frame last card, learned straight off the utility set');
      expect(learned[117], FirmwareProduct.sogwave1Ph.d0ByCount[117]);
    });
  });

  group('where the files are saved', () {
    test('everything goes to Outputs_Files beside the app, found from where it runs', () async {
      final dir = await AppState.outputDir();
      expect(AppState.outputFolderName, 'Outputs_Files');
      // the tests run in src_file, so its parent's Outputs_Files is the one the app uses as well
      final beside = '${Directory.current.parent.path}\\${AppState.outputFolderName}';
      expect(dir.path, beside);
      expect(dir.existsSync(), isTrue, reason: 'the folder is made when it is not there');
      // it is the folder the user keeps, inside the tool folder, not somewhere under the user profile
      expect(dir.path.toLowerCase(), contains('smartcrad_nfc_app'));
      expect(dir.path.toLowerCase(), isNot(contains('documents')));
    });

    test('a report really lands there', () async {
      final state = AppState(); // writeFiles on, as in the app
      state.selected = SimulatedCard.key;
      await state.connect();
      await state.runCheck();
      final path = await state.saveHtmlReport(open: false);
      expect(path, isNotNull, reason: 'the report should have been written');
      final file = File(path!);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      expect(file.existsSync(), isTrue);
      expect(file.parent.path, (await AppState.outputDir()).path);
      expect(file.readAsStringSync(), startsWith('<!doctype html>'));
      state.dispose();
    });
  });

  group('block editor', () {
    test('reads a chosen run of blocks, and the bytes match the card', () async {
      final state = AppState(writeFiles: false);
      state.selected = SimulatedCard.key;
      await state.connect();
      // read blocks 1 and 2 (offset 0x10, 32 bytes): the simulator has "EMG METER CARD - SIMULATOR" at 0x10
      final data = await state.readBlocks(0x10, 32);
      expect(data, isNotNull);
      expect(data, hasLength(32));
      expect(String.fromCharCodes(data!.sublist(0, 26)), 'EMG METER CARD - SIMULATOR');
      expect(data, _cardBytes(state.simulator, 0x10, 32));
      state.dispose();
    });

    test('a range outside the card is refused', () async {
      final state = AppState(writeFiles: false);
      state.selected = SimulatedCard.key;
      await state.connect();
      expect(await state.readBlocks(0x7FF0, 32), isNull, reason: '0x7FF0 + 32 runs past 7FFF');
      expect(await state.readBlocks(-16, 16), isNull);
      state.dispose();
    });

    test('the last blocks 7FE0 and 7FF0 read, including the special 7FFF byte', () async {
      final state = AppState(writeFiles: false);
      state.selected = SimulatedCard.key;
      await state.connect();
      final card = state.simulator;
      // 7FE0: a full 16-byte block inside the main buffer
      final a = await state.readBlocks(0x7FE0, 16);
      expect(a, isNotNull);
      expect(a, _cardBytes(card, 0x7FE0, 16));
      // 7FF0: the last block, 7FF0-7FFF, where 7FFF lives in the applet's extra byte
      final b = await state.readBlocks(0x7FF0, 16);
      expect(b, isNotNull, reason: 'the last block must read');
      expect(b, hasLength(16));
      expect(b, _cardBytes(card, 0x7FF0, 16));
      // the simulator fills 7FF0-7FFE with A0..AE and 7FFF with 5A
      expect(b!.sublist(0, 15), Uint8List.fromList(List.generate(15, (i) => 0xA0 + i)));
      expect(b[15], 0x5A, reason: 'byte 7FFF');
      state.dispose();
    });

    test('an edited block is written back, and only the changed block is sent', () async {
      final state = AppState(writeFiles: false);
      state.selected = SimulatedCard.key;
      await state.connect();
      final card = state.simulator;
      await state.readBlocks(0x20, 48); // blocks 2,3,4 at 0x20 (the simulator has FF there)
      final before = _cardBytes(card, 0x20, 48);

      // change only the middle block (0x30), via a write request as the editor builds it
      final edited = Uint8List.fromList(before);
      edited.fillRange(16, 32, 0xAB); // block at 0x30
      final sent0 = state.logEntries.where((e) => e.kind == LogKind.sent && e.text.contains('[Write card: UPDATE')).length;
      await state.writeCard(CardWriteRequest(0x20, edited, source: 'block editor'), skipUnchanged: true);
      expect(state.writeResult!.ok, isTrue, reason: state.writeResult!.message);
      expect(state.writeResult!.partsWritten, 1, reason: 'only the one changed block is written');
      final sent1 = state.logEntries.where((e) => e.kind == LogKind.sent && e.text.contains('[Write card: UPDATE')).length;
      expect(sent1 - sent0, 1);
      // the card holds the edit, and the untouched blocks are unchanged
      expect(_cardBytes(card, 0x30, 16), Uint8List(16)..fillRange(0, 16, 0xAB));
      expect(_cardBytes(card, 0x20, 16), Uint8List.sublistView(before, 0, 16));
      expect(_cardBytes(card, 0x40, 16), Uint8List.sublistView(before, 32, 48));
      // and it can be undone
      await state.undoLastWrite();
      expect(_cardBytes(card, 0x20, 48), before);
      state.dispose();
    });
  });

  group('Write card in the app', () {
    test('writes, clears the old read, and Undo puts back what was there', () async {
      final state = AppState(writeFiles: false);
      state.selected = SimulatedCard.key;
      await state.connect();
      await state.readCard(openReport: false);
      expect(state.readResult, isNotNull);
      final card = state.simulator;
      final before = _cardBytes(card, 0x10, text.length);

      await state.writeCard(CardWriteRequest(0x10, text, source: 'typed'));
      expect(state.writeResult!.ok, isTrue, reason: state.writeResult!.message);
      expect(state.readResult, isNull, reason: 'what Read card showed is not on the card any more');
      expect(state.undoable, isNotNull);
      expect(_cardBytes(card, 0x10, text.length), text);

      await state.undoLastWrite();
      expect(state.writeResult!.ok, isTrue, reason: state.writeResult!.message);
      expect(state.writeResult!.request.source, startsWith('undo of 0010-001D'));
      expect(state.undoable, isNull, reason: 'nothing is left to put back');
      expect(_cardBytes(card, 0x10, text.length), before);

      // a write that cannot fit is refused in the app too, and nothing changes
      await state.writeCard(CardWriteRequest(0x7FFF, Uint8List(2)));
      expect(state.writeResult!.request.offset, 0x10, reason: 'the refused write did not start');
      state.dispose();
    });
  });

  for (final size in const [Size(1440, 900), Size(1100, 700)]) {
    testWidgets('Write card pressed through at ${size.width.toInt()} x ${size.height.toInt()}: write, check, undo, fill',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState(writeFiles: false);
      state.selected = SimulatedCard.key;
      await tester.pumpWidget(NfcTesterApp(state: state));
      await tester.runAsync(() => state.connect());
      state.setPage(Pages.read);
      await tester.pump(const Duration(milliseconds: 400));

      Finder onPage(Finder f) => find.descendant(of: find.byType(ReadPage), matching: f);
      Future<void> waitFor(bool Function() done, String what) async {
        for (var i = 0; i < 400 && !done(); i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(done(), isTrue, reason: 'waiting for $what');
        await tester.pump(const Duration(milliseconds: 400));
      }

      Future<void> press(Finder f) async {
        state.messengerKey.currentState
          ?..clearSnackBars()
          ..removeCurrentSnackBar();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.ensureVisible(f);
        await tester.pump();
        await tester.tap(f);
        await tester.pump();
      }

      // the switch at the top turns the page to Write card
      await press(onPage(find.text('Write card')));
      expect(onPage(find.text('What to write')), findsOneWidget);
      expect(onPage(find.text('Nothing to write yet')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'the empty write page');

      // typed bytes: shown before anything is sent
      await tester.enterText(onPage(find.widgetWithText(TextField, 'Offset (hex)')), '0010');
      await tester.enterText(onPage(find.widgetWithText(TextField, 'Bytes (hex)')), '48 45 4C 4C 4F');
      await tester.pump(const Duration(milliseconds: 300));
      expect(onPage(find.textContaining('Ready: 5 bytes at 0010-0014')), findsOneWidget);
      expect(onPage(find.text('5 bytes  ->  0010-0014')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'the page with bytes typed');

      // write, after the dialog
      await press(onPage(find.text('Write to card')));
      expect(find.text('Write 5 bytes to the card?'), findsOneWidget);
      await press(find.text('Write it'));
      await waitFor(() => !state.busy && state.writeResult != null, 'the write');
      expect(state.writeResult!.ok, isTrue, reason: state.writeResult!.message);
      expect(onPage(find.textContaining('OK: the 5 bytes at 0010-0014 are on the card')), findsOneWidget);
      expect(onPage(find.text('Written to the card')), findsOneWidget);
      expect(_cardBytes(state.simulator, 0x10, 5), 'HELLO'.codeUnits);
      expect(tester.takeException(), isNull, reason: 'the page with a write done');

      // undo, after its own dialog
      await press(onPage(find.text('Undo last write')));
      expect(find.text('Undo the last write?'), findsOneWidget);
      await press(find.text('Undo it'));
      await waitFor(() => !state.busy && state.undoable == null, 'the undo');
      expect(state.writeResult!.ok, isTrue);
      expect(_cardBytes(state.simulator, 0x10, 5), 'EMG M'.codeUnits, reason: 'the demo text is back');

      // a fill: 00 over one block
      await press(onPage(find.text('Fill')));
      await tester.enterText(onPage(find.widgetWithText(TextField, 'From (hex)')), '2000');
      await tester.enterText(onPage(find.widgetWithText(TextField, 'To (hex)')), '20FF');
      await tester.pump(const Duration(milliseconds: 300));
      await press(onPage(find.text('Write to card')));
      await press(find.text('Write it'));
      await waitFor(() => !state.busy && state.writeResult?.request.source == 'fill 00', 'the fill');
      expect(state.writeResult!.ok, isTrue, reason: state.writeResult!.message);
      expect(_cardBytes(state.simulator, 0x2000, 256), everyElement(0));
      expect(tester.takeException(), isNull, reason: 'the page after a fill');

      // and back to Read card, which still works
      await press(onPage(find.text('Read card')));
      expect(onPage(find.text('Read whole card')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }
}
