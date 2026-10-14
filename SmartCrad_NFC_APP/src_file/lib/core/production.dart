import 'dart:typed_data';

import '../card/card_channel.dart';
import 'apdu.dart';
import 'applet.dart';
import 'card_reader.dart';
import 'card_test.dart';
import 'errors.dart';
import 'hex.dart';
import 'ios_rules.dart';
import 'log.dart';
import 'phone_check.dart';
import 'platform.dart';

/// Checks that belong to "is this card ready to ship", and that none of the other screens makes on its own.
///
/// They go straight to the reader, not through the phone rules: they are about the card, not about a phone. Nothing
/// is written.
class ProductionChecks {
  ProductionChecks(this.channel, this.log, {required this.appletAid});

  /// How many times the card is powered down and up, to see that it answers every time.
  static const taps = 5;

  final CardChannel channel;
  final Logger log;
  final Uint8List appletAid;

  final List<StepRow> rows = [];

  void _add(String step, String result, String details) => rows.add(StepRow(step, result, details));

  Future<ResponseApdu> _send(String hex) async {
    final apdu = Hex.parse(hex);
    final watch = Stopwatch()..start();
    final r = ResponseApdu.fromRaw(await channel.transmit(apdu));
    log.exchange('production check', apdu, r, watch.elapsedMicroseconds / 1000);
    return r;
  }

  Future<List<StepRow>> run() async {
    log.section('Production checks');
    try {
      await _defaultApplet();
      await _cardId();
      await _reachableByAid();
      await _dataFile();
      _aidCategory();
    } on CardException catch (e) {
      _add('Production checks', 'FAIL', 'The card stopped answering: ${e.message}');
    }
    return rows;
  }

  /// The card must pick the applet by itself after a power-up, or a phone app has to know the AID to reach it at all,
  /// and anything that relies on a tap alone stops working.
  Future<void> _defaultApplet() async {
    await channel.fieldReset();
    final r = await _send('80 08 00 00 0A');
    final ok = r.sw == 0x9000 && r.data.length == 10;
    _add(
      'The card selects the applet by itself',
      ok ? 'OK' : 'FAIL',
      ok
          ? 'After a power-up, GET UID answered 90 00 with 10 bytes without any SELECT, so the applet holds the '
              '"default selected" privilege.'
          : 'After a power-up, GET UID answered ${r.swText} instead of 90 00 and a card ID. The applet is not the '
              'default selected one, so an app only reaches it by selecting its AID. Install it with "Default '
              'selected" in the burner.',
    );
  }

  /// A card ID that is all zeros, all FF, or different at every tap cannot identify a card to a back end.
  Future<void> _cardId() async {
    final first = await _send('80 08 00 00 0A');
    if (first.sw != 0x9000 || first.data.length != 10) {
      _add('The card ID is usable', 'FAIL', 'GET UID answered ${first.swText}; a 10-byte card ID is expected.');
      return;
    }
    final id = first.data;
    final allSame = id.every((b) => b == id[0]);
    if (allSame) {
      _add('The card ID is usable', 'FAIL',
          'The card ID is ${Hex.of(id)}: every byte is the same, so it cannot tell this card from another.');
    } else {
      _add('The card ID is usable', 'OK', 'Card ID ${Hex.of(id)} (10 bytes).');
    }

    var sameEveryTime = true;
    for (var i = 1; i < taps; i++) {
      await channel.fieldReset();
      final again = await _send('80 08 00 00 0A');
      if (again.sw != 0x9000 || !Hex.same(again.data, id)) {
        sameEveryTime = false;
        _add('The card ID stays the same', 'FAIL',
            'Tap ${i + 1} of $taps gave ${again.sw == 0x9000 ? Hex.of(again.data) : again.swText}, not ${Hex.of(id)}. '
                'A back end that stores the card ID would not recognise this card again.');
        break;
      }
    }
    if (sameEveryTime) {
      _add('The card ID stays the same', 'OK', 'The same card ID came back from all $taps power-ups.');
    }
    _add('The card answers every tap', sameEveryTime ? 'OK' : 'WARN',
        '$taps power-ups in a row, each followed by GET UID.');
  }

  /// A phone app that lists the AID must be able to select it, whether or not it is the default applet.
  Future<void> _reachableByAid() async {
    await channel.fieldReset();
    final r = await _send(AppletAid.select(appletAid));
    final ok = r.sw == 0x9000;
    _add(
      'An app can select the applet by its AID',
      ok ? 'OK' : 'FAIL',
      ok
          ? 'SELECT ${Hex.of(appletAid)} answered 90 00.'
          : 'SELECT ${Hex.of(appletAid)} answered ${r.swText}. No app that lists this AID would find the card. '
              'Check the AID box, and what the burner shows as installed.',
    );
  }

  /// The 32 KB file has to be there and readable, or there is nothing for a meter to store.
  Future<void> _dataFile() async {
    final select = await _send('00 A4 00 00 02 30 40');
    if (select.sw != 0x9000) {
      _add('The data file EF 3040 is there', 'FAIL', 'SELECT 3040 answered ${select.swText}.');
      return;
    }
    final first = await _send('00 B0 00 00 10');
    final last = await _send('00 B0 7F FF 01');
    final ok = first.sw == 0x9000 && first.data.length == 16 && last.sw == 0x9000 && last.data.length == 1;
    _add(
      'The data file EF 3040 is there',
      ok ? 'OK' : 'FAIL',
      ok
          ? 'The first 16 bytes and the last byte (7FFF) both read, so the whole ${CardTest.fullSize}-byte file is '
              'addressable.'
          : 'The first bytes answered ${first.swText} and the last byte ${last.swText}.',
    );
  }

  /// An AID outside the registered categories is the one thing a PC reader cannot settle for an iPhone.
  void _aidCategory() {
    final digit = appletAid[0] >> 4;
    final standard = digit == 0xA || digit == 0xD || digit == 0xF;
    _add(
      'The AID is in a registered category',
      standard ? 'OK' : 'WARN',
      standard
          ? '${Hex.of(appletAid)}: ${IosRules.category(appletAid)}.'
          : '${Hex.of(appletAid)} starts with ${digit.toRadixString(16).toUpperCase()}. Registered AIDs start with A '
              'or D and proprietary ones with F. Apple has no written rule against it, but one developer saw iOS '
              'refuse such an AID, and only a real iPhone can settle it.',
    );
  }
}

// ------------------------------------------------------------------ putting every run together

/// What one phone's runs came to.
class PlatformOutcome {
  PlatformOutcome({
    required this.platform,
    required this.checkRows,
    required this.checkVerdict,
    required this.checkYes,
    required this.checkWarnings,
    required this.read,
    required this.testRows,
    required this.testSummary,
    required this.cardSize,
  });

  final PhonePlatform platform;
  final List<StepRow> checkRows;
  final String checkVerdict;
  final bool? checkYes;
  final int checkWarnings;
  final CardReadResult? read;
  final List<CheckRow> testRows;
  final String testSummary;
  final int? cardSize;

  int get testFailures => testRows.where((r) => r.result == 'FAIL').length;
  int get testPassed => testRows.where((r) => r.result == 'PASS').length;
  bool get readOk => read?.ok ?? false;
}

/// One line of the final verdict: a stage and how it went.
class StageOutcome {
  StageOutcome(this.name, this.result, this.detail);

  final String name;
  final String result; // OK, WARN, FAIL
  final String detail;
}

/// The whole picture: every stage, the extra checks, and whether the card is ready to ship.
class ProductionSummary {
  ProductionSummary(this.platforms, this.extraChecks, {this.simulated = false}) {
    for (final p in platforms) {
      final phone = p.platform.short;
      stages.add(StageOutcome(
        '$phone check',
        p.checkYes == true ? (p.checkWarnings > 0 ? 'WARN' : 'OK') : 'FAIL',
        p.checkVerdict.isEmpty ? 'did not run' : p.checkVerdict,
      ));
      stages.add(StageOutcome(
        '$phone read card',
        p.readOk ? (p.read!.warnings.isEmpty ? 'OK' : 'WARN') : 'FAIL',
        p.read?.message ?? 'did not run',
      ));
      stages.add(StageOutcome(
        '$phone card unit test',
        p.testRows.isEmpty ? 'FAIL' : (p.testFailures == 0 ? 'OK' : 'FAIL'),
        p.testSummary.isEmpty ? 'did not run' : p.testSummary,
      ));
    }
    for (final row in extraChecks) {
      stages.add(StageOutcome(row.step, row.result == 'INFO' ? 'OK' : row.result, row.details));
    }
  }

  final List<PlatformOutcome> platforms;
  final List<StepRow> extraChecks;

  /// True when this ran against the built-in simulated card. The result then says nothing about real hardware, so it
  /// is written next to the verdict rather than left for someone to spot in the setup table.
  final bool simulated;

  final List<StageOutcome> stages = [];

  int get failures => stages.where((s) => s.result == 'FAIL').length;
  int get warnings => stages.where((s) => s.result == 'WARN').length;
  bool get ready => failures == 0;

  /// The size every read and every test agreed on, or null when they did not agree.
  int? get cardSize {
    final sizes = platforms.map((p) => p.cardSize).whereType<int>().toSet();
    return sizes.length == 1 ? sizes.first : null;
  }

  /// Said first when it matters more than the verdict itself.
  static const simulatorNote = 'This ran against the SIMULATED card, not a real one, so it says nothing about your '
      'hardware. Connect the reader with the card on it and run it again.';

  String get verdict {
    if (platforms.isEmpty) return 'Nothing was run yet.';
    final head = simulated ? '$simulatorNote ' : '';
    if (failures > 0) {
      return '${head}NOT READY: $failures ${failures == 1 ? 'check' : 'checks'} failed. '
          'The card should not go to production until each one is understood.';
    }
    if (warnings > 0) {
      return '${head}READY, with $warnings ${warnings == 1 ? 'warning' : 'warnings'}. Everything works; read the '
          'warnings below and decide whether each one matters for your product.';
    }
    return '${head}READY: every check passed on both phones.';
  }
}
