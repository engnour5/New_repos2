import 'dart:typed_data';

import '../card/card_channel.dart';
import '../card/simulated_card.dart';
import '../core/errors.dart';
import '../core/hex.dart';
import '../core/log.dart';
import 'cap_file.dart';
import 'card_manager.dart';
import 'cplc.dart';
import 'gp_keys.dart';

/// What the batch burner is doing right now, so the screen can say it in one word.
enum BatchStage {
  /// Nothing yet, or it has stopped.
  idle,

  /// Nothing on the reader: put the next card on.
  waitingForCard,

  /// A card is on the reader and is being burned.
  burning,

  /// This card is done: take it off, and the next one goes on.
  waitingForRemoval,
}

extension BatchStageText on BatchStage {
  String get label => switch (this) {
        BatchStage.idle => 'Not running',
        BatchStage.waitingForCard => 'Put the next card on the reader',
        BatchStage.burning => 'Burning',
        BatchStage.waitingForRemoval => 'Take the card off the reader',
      };
}

/// One card of a batch: what happened to it.
class BatchCard {
  BatchCard({
    required this.number,
    required this.ok,
    required this.message,
    required this.seconds,
    required this.finishedAt,
    this.cardId,
    this.nfcUid,
    this.chip,
  });

  /// 1 for the first card of the run, 2 for the next, and so on.
  final int number;
  final bool ok;
  final String message;
  final double seconds;
  final DateTime finishedAt;

  /// The card ID the applet reports to GET UID (80 08) after the burn. It is made afresh by every install, so it is
  /// the one number that names this card for good.
  final Uint8List? cardId;

  /// The contactless UID the reader saw. On this card it is random at every power-up, so it names the tap rather than
  /// the card; it is kept because it is what a phone's own Tag.getId() would show.
  final Uint8List? nfcUid;

  /// What the chip maker burned into this card. It is read before the burn and never changes, so it is the one name
  /// that still fits the card after it has been burned again.
  final Cplc? chip;

  /// The chip's fixed name, or an empty string when the card does not keep one.
  String get chipId => chip?.chipId ?? '';

  /// The line that goes in the log and on the screen. The chip is named first, because that is the name that lasts.
  String get line => ok
      ? 'OK finished for $number'
          '${chipId.isEmpty ? '' : '  (chip $chipId)'}'
          '${cardId == null ? '' : '  card ID ${Hex.compact(cardId)}'}'
          '  ${seconds.toStringAsFixed(1)} s'
      : 'FAILED for $number${chipId.isEmpty ? '' : ' (chip $chipId)'}: $message';
}

/// Burns the same CAP, with the same settings, onto one card after another.
///
/// Press once and the operator only swaps cards: it waits for a card, burns it, says "OK finished for N", waits for
/// that card to be taken off, and waits for the next. Nothing is burned twice, because a card has to leave the reader
/// before the next one is counted.
///
/// It stops when [stop] is called, or after [stopAfterFailures] cards in a row have failed, so a wrong key or a wrong
/// CAP cannot sit there spoiling a whole tray.
class BatchBurn {
  BatchBurn({
    required this.channel,
    required this.log,
    required this.keys,
    required this.cap,
    required this.instanceAid,
    required this.moduleAid,
    this.defaultSelected = true,
    this.deleteFirst = true,
    this.force = false,
    this.onChanged,
    this.poll = const Duration(milliseconds: 400),
    this.stopAfterFailures = 3,
  });

  final CardChannel channel;
  final Logger log;
  final GpKeys keys;
  final CapFile cap;
  final Uint8List instanceAid;
  final Uint8List moduleAid;
  final bool defaultSelected;
  final bool deleteFirst;

  /// Delete whatever already uses the instance AID (and whatever holds "Default selected") before installing, so a card
  /// that was burned before takes the new applet instead of being refused.
  final bool force;

  /// Called whenever the stage or the counts change, so a screen can follow along.
  final void Function()? onChanged;

  /// How long to wait between two looks at the reader.
  final Duration poll;

  /// How many cards in a row may fail before the run gives up. 0 means never give up.
  final int stopAfterFailures;

  final List<BatchCard> cards = [];
  BatchStage stage = BatchStage.idle;
  bool running = false;

  /// Why the run ended, once it has.
  String? stopped;

  int get done => cards.length;
  int get ok => cards.where((c) => c.ok).length;
  int get failed => cards.where((c) => !c.ok).length;
  int get failuresInARow {
    var n = 0;
    for (final c in cards.reversed) {
      if (c.ok) break;
      n++;
    }
    return n;
  }

  /// Asks the run to stop. The card being burned is always finished first, so a card is never left half written.
  void stop([String why = 'you stopped it']) {
    if (!running) return;
    stopped = why;
    running = false;
    _set(BatchStage.idle);
  }

  void _set(BatchStage s) {
    stage = s;
    onChanged?.call();
  }

  /// Runs until [stop] is called or too many cards fail in a row.
  Future<void> run() async {
    running = true;
    stopped = null;
    log.section('Auto load: burning ${cap.name} onto one card after another');
    try {
      while (running) {
        // Let everything else have a turn between cards. Without this a card that answers with no waiting at all
        // (the simulator, and a very quick reader) makes a loop of nothing but microtasks, which starves the timers
        // the screen and the Stop button run on: the app would look frozen and could not be stopped.
        await Future<void>.delayed(Duration.zero);
        if (!await _waitFor(present: true)) break;
        if (!running) break;
        _set(BatchStage.burning);
        final card = await _burnOne(done + 1);
        cards.add(card);
        if (card.ok) {
          log.info('Auto load: ${card.line}');
        } else {
          log.warn('Auto load: ${card.line}');
        }
        onChanged?.call();
        if (stopAfterFailures > 0 && failuresInARow >= stopAfterFailures) {
          stop('$failuresInARow cards in a row failed');
          log.warn('Auto load stopped: $failuresInARow cards in a row failed. Check the keys, the CAP and the cards.');
          break;
        }
        if (!running) break;
        if (!await _waitFor(present: false)) break;
      }
    } finally {
      running = false;
      _set(BatchStage.idle);
      log.info('Auto load finished: $ok burned, $failed failed, $done card${done == 1 ? '' : 's'} in all'
          '${stopped == null ? '' : ' ($stopped)'}.');
    }
  }

  /// One card: open a channel with the card's keys and load the CAP, exactly as the Burner's own button does.
  Future<BatchCard> _burnOne(int number) async {
    final watch = Stopwatch()..start();
    final gp = CardManager(channel, log);
    Cplc? chip;
    try {
      // what the chip maker burned in, read before anything is changed, so a card that then fails is still named
      await gp.selectAid(gp.isdAid);
      chip = await Cplc.read(channel);
      if (chip != null) {
        log.info('Card $number: chip ${chip.chipId}${chip.fabricator.isEmpty ? '' : ' (${chip.fabricator})'}.');
      }
      await gp.authenticate(keys);
      final before = await gp.readCard();
      if (force) {
        // delete whatever is in the way first (the applet using the AID, the default-selected one, the package), so a
        // card burned before is overwritten instead of refused
        for (final (aid, withRelated) in before.blockers(cap.packageAid, instanceAid: instanceAid, defaultSelected: defaultSelected)) {
          log.info('Card $number: force-deleting ${Hex.of(aid)}, which is in the way.');
          try {
            await gp.delete(aid, withRelated: withRelated);
          } on GpException catch (e) {
            if (e.sw != 0x6A88) rethrow; // already gone is fine
          }
        }
      } else {
        final problem = before.loadProblem(cap.packageAid,
            instanceAid: instanceAid, defaultSelected: defaultSelected, deleteFirst: deleteFirst);
        if (problem != null) throw GpException('$problem Nothing was sent to this card.');
        if (deleteFirst && before.package(cap.packageAid) != null) {
          await gp.delete(cap.packageAid);
        }
      }
      await gp.loadCap(cap,
          instanceAid: instanceAid, moduleAid: moduleAid, privileges: defaultSelected ? 0x04 : 0x00);
      final (id, uid) = await _identify();
      return BatchCard(
        number: number,
        ok: true,
        message: 'loaded and installed',
        seconds: watch.elapsedMicroseconds / 1e6,
        finishedAt: DateTime.now(),
        cardId: id,
        nfcUid: uid,
        chip: chip,
      );
    } on CardException catch (e) {
      return BatchCard(
        number: number,
        ok: false,
        message: e is GpException ? e.toString() : e.message,
        seconds: watch.elapsedMicroseconds / 1e6,
        finishedAt: DateTime.now(),
        chip: chip,
      );
    } catch (e) {
      return BatchCard(
          number: number,
          ok: false,
          message: '$e',
          seconds: watch.elapsedMicroseconds / 1e6,
          finishedAt: DateTime.now(),
          chip: chip);
    } finally {
      gp.close();
    }
  }

  /// What names the card after the burn: the applet's card ID, and the UID the reader saw. Never fails the burn.
  Future<(Uint8List?, Uint8List?)> _identify() async {
    Uint8List? id, uid;
    try {
      await channel.fieldReset();
      uid = await channel.getUid();
      final select = await channel.transmit(Hex.parse(
          '00 A4 04 00 ${h2(instanceAid.length)} ${Hex.of(instanceAid)} 00'));
      if (select.length >= 2 && select[select.length - 2] == 0x90) {
        final r = await channel.transmit(Hex.parse('80 08 00 00 0A'));
        if (r.length == 12 && r[10] == 0x90 && r[11] == 0x00) id = Hex.sub(r, 0, 10);
      }
    } on CardException {
      // naming the card is a nicety: a burn that worked still counts
    }
    return (id, uid);
  }

  /// Waits until a card is on the reader ([present] true) or off it ([present] false).
  ///
  /// Returns false when the run was stopped while waiting. The simulated card has no one to swap it, so it is given a
  /// fresh card instead and the wait is over at once: that is what makes this testable without a tray of cards.
  Future<bool> _waitFor({required bool present}) async {
    _set(present ? BatchStage.waitingForCard : BatchStage.waitingForRemoval);
    final simulator = channel is SimulatedCard ? channel as SimulatedCard : null;
    if (simulator != null) {
      await Future<void>.delayed(Duration.zero); // the same turn for everything else as a real swap would give
      if (present) {
        simulator.insertNewCard(); // the next blank card of the tray
        await simulator.connect();
      } else {
        await simulator.disconnect();
      }
      return running;
    }
    // A reader hands back the connection it already has without looking at the card again, so while we hold one
    // every answer would be "still there" and the wait would never end. Letting go first makes each look a real one.
    if (!present) await _letGo();
    while (running) {
      final on = await _cardIsOn();
      if (on == present) return running;
      // we had to connect to find that out: let go again, or the next look would come from the same held connection
      if (!present && on) await _letGo();
      await Future<void>.delayed(poll);
    }
    return false;
  }

  /// True when a card answers on the reader. Connecting is the test: with no card the reader says so at once.
  Future<bool> _cardIsOn() async {
    try {
      await channel.connect();
      return true;
    } on CardException {
      return false;
    }
  }

  /// Drops the connection so the next connect really asks the reader. A card already gone is not a problem.
  Future<void> _letGo() async {
    try {
      await channel.disconnect();
    } on CardException {
      // it is already gone, which is what we were waiting for
    }
  }
}
