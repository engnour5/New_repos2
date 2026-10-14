import 'dart:typed_data';

import 'apdu.dart';
import 'applet.dart';
import 'error_map.dart';
import 'errors.dart';
import 'hex.dart';
import 'log.dart';
import 'platform.dart';
import 'session.dart';

/// Where a row belongs in the results: the phone steps, the card_test.ps1 checks, or the extra checks.
enum CheckGroup { steps, forty, extra }

class CheckRow {
  CheckRow(this.id, this.result, this.check, this.apdu, this.expected, this.got, this.ms, this.group, {this.answer});

  final String id;
  final String result; // PASS, FAIL, NOTE, BLOCKED
  final String check;
  final String apdu;
  final String expected;
  final String got;
  final double ms;
  final CheckGroup group;

  /// The type of the card's answer, from the error map. Null when no answer came back.
  final AnswerType? answer;

  /// True when the command never reached the card ("not sent: ..." or "not run: ...").
  bool get notSent => got.startsWith('not sent') || got.startsWith('not run');
}

/// The card unit test, run the way a phone app would run it:
/// - tap 1: card_test.ps1 checks C01-C31 (minus the strict-validation edge cases C16-C22/C24-C26/C28 that the lenient
///   applet intentionally does not match - they were removed), the extra checks X02-X12 (with the card size), then the restore
///   C37-C40 and X13-X14;
/// - tap 2: the power-cycle checks C32-C36 and X15.
/// Every check runs, even after a failure, so a card that answers wrongly (an old applet, for example) shows all its
/// answers. A check that cannot reach the card is listed as FAIL with the reason, so there are always 47 rows.
/// The bytes the test changes (0000-003F, 0100-01FE and 7FC0-7FFF) are saved first and written back. When they cannot
/// be saved, no command that writes is sent.
class CardTest {
  CardTest(this.s, this.log, {this.onRow, Uint8List? appletAid}) : appletAid = appletAid ?? AppletAid.byDefault;

  static const fullSize = 32768;

  /// The applet this run selects. It comes from the AID box, so a freshly burned applet is tested, not the old one.
  final Uint8List appletAid;

  /// SELECT of that applet, with a length byte that matches it.
  String get selectApplet => AppletAid.select(appletAid);

  /// Rows a full run produces: 4 phone steps, the card_test.ps1 checks and the extra checks.
  static const expectedRows = 47;

  final PhoneSession s;
  final Logger log;
  final void Function(CheckRow row)? onRow;
  final List<CheckRow> rows = [];
  String summary = '';

  /// Bytes the card returned when it was read until it stopped (X12), or null when X12 could not send anything.
  int? cardSize;
  String cardSizeStop = '';

  /// True when the answers show the original applet (80 A4 returns the card ID instead of 6E 00).
  bool originalApplet = false;

  bool _viaSession = true; // false when the session ended during the restore: it then goes straight to the reader
  bool _restoring = false;
  String _restoredText = 'nothing was written';
  String? _noWrites; // why the checks that write are not sent (the bytes could not be saved first)
  CardException? _lost; // the first error of the reader or the card: later commands are listed as not sent
  bool _everFound = false;
  Uint8List? _cardId;

  PhonePlatform get platform => s.platform;
  int get failed => rows.where((r) => r.result == 'FAIL').length;

  /// Runs every check. When the card or the reader failed on the way, the first error is thrown at the end, after
  /// all the rows and the summary are made, so the app can still tell that the connection is lost.
  Future<void> run() async {
    try {
      await _runAll();
    } finally {
      _makeSummary();
    }
    final lost = _lost;
    if (lost != null) throw lost;
  }

  Future<void> _runAll() async {
    Uint8List? saved0, saved1, saved7;
    final phone = platform.short;

    log.section('Card Unit Test as an ${platform.app}, tap 1');
    try {
      if (!await _tap('S1', 'Tap 1: the $phone finds the card')) {
        log.warn('The $phone did not find the card. Every check of tap 1 is listed as not sent.');
      }

      log.section('0. which applet is on the card (read-only)');
      final select = await _check('C01', 'SELECT applet by AID ${AppletAid.short(appletAid)}', selectApplet, '9000');
      if (select != null && select.ok && !_is(select, 0x9000)) {
        log.warn('The applet does not answer its SELECT by AID (${select.short}). The checks go on anyway, so you can '
            'see how the card answers each one.');
      }
      final uid = await _check('C02', 'GET UID (80 08)', '80 08 00 00 0A', '9000', expLength: 10);
      if (_is(uid, 0x9000) && uid!.response!.data.length == 10) _cardId = uid.response!.data;

      log.section('1. save the bytes the tests may change');
      await _check('C03', 'SELECT EF 3040', '00 A4 00 00 02 30 40', '9000');
      saved0 = await _save('00 B0 00 00 40', 64, '0000-003F');
      if (saved0 != null) saved1 = await _save('00 B0 01 00 FF', 255, '0100-01FE');
      if (saved1 != null) saved7 = await _save('00 B0 7F C0 40', 64, '7FC0-7FFF');
      if (saved7 == null) {
        saved0 = null;
        saved1 = null;
      }

      log.section('2. normal meter use');
      await _check('C04', 'READ 256 bytes (Le 00)', '00 B0 00 00 00', '9000', expLength: 256);
      await _check('C05', 'READ last 256 bytes, up to 7FFF', '00 B0 7F 00 00', '9000', expLength: 256);
      await _check('C06', 'UPDATE 4 bytes at 0020', '00 D6 00 20 04 11 22 33 44', '9000', write: true);
      await _check('C07', 'READ them back', '00 B0 00 20 04', '9000', expData: '11 22 33 44', write: true);
      await _check('C08', 'UPDATE 2 bytes ending on 7FFF', '00 D6 7F FE 02 AA BB', '9000', write: true);
      await _check('C09', 'READ them back', '00 B0 7F FE 02', '9000', expData: 'AA BB', write: true);
      await _check('C10', 'UPDATE only the last byte 7FFF', '00 D6 7F FF 01 5A', '9000', write: true);
      await _check('C11', 'READ only the last byte', '00 B0 7F FF 01', '9000', expData: '5A', write: true);
      await _readWholeFile();

      log.section('3. error map');
      final c13 = await _check('C13', 'SELECT with wrong CLA', '80 A4 00 00 02 30 40', '6E00');
      if (_is(c13, 0x9000) && c13!.response!.data.length == 10) {
        originalApplet = true;
        log.warn('80 A4 answered 90 00 and a card ID: the card runs the ORIGINAL applet, which falls through to GET UID.');
      }
      await _check('C14', 'GET UID with CLA 00 (old hidden write)', '00 08 00 20 02 CA FE', '6E00', write: true);
      await _check('C15', '  ...and 0020 was not written', '00 B0 00 20 02', '9000', expData: '11 22', write: true);
      await _check('C23', 'READ with wrong CLA', '84 B0 00 00 10', '6E00');
      await _check('C27', 'Unknown instruction', '00 CA 00 00 00', '6D00');
      // De-select the EF (the removed C16/C17/C28 SELECTs used to leave it de-selected) so C29 can still prove that a
      // READ now needs SELECT 3040 again. Sent as a plain exchange, not a check, so it adds no row.
      await _exchange('00 A4 00 00 02 3F 00', 'C29 setup: SELECT MF 3F00 (de-selects the EF)');
      await _check('C29', 'after SELECT MF, READ needs SELECT 3040 again', '00 B0 00 00 02', '6986');
      await _selectUnknownAid();
      await _check('C31', 'SELECT the applet again', selectApplet, '9000');

      log.section('4. extra checks');
      await _check('X02', 'SELECT EF 3040 with P1 = 02', '00 A4 02 00 02 30 40', '9000', group: CheckGroup.extra);
      await _check('X03', 'UPDATE with wrong CLA', '84 D6 00 00 02 11 22', '6E00', write: true, group: CheckGroup.extra);
      await _check('X04', 'SELECT MF 3F00 by file ID', '00 A4 00 00 02 3F 00', '9000', group: CheckGroup.extra);
      await _check('X05', '  ...then UPDATE needs SELECT 3040 (nothing written)', '00 D6 00 00 02 11 22', '6986',
          write: true, group: CheckGroup.extra);
      await _check('X06', 'SELECT EF 3040', '00 A4 00 00 02 30 40', '9000', group: CheckGroup.extra);
      final pattern = Hex.of(List<int>.generate(255, (i) => i));
      await _check('X07', 'UPDATE 255 bytes at 0100 (the largest short command)', '00 D6 01 00 FF $pattern', '9000',
          write: true, group: CheckGroup.extra);
      await _check('X08', '  ...READ the 255 bytes back', '00 B0 01 00 FF', '9000', expData: pattern, write: true,
          group: CheckGroup.extra);
      await _check('X09', 'READ 255 bytes ending exactly on 7FFF', '00 B0 7F 01 FF', '9000', expLength: 255, group: CheckGroup.extra);
      await _check('X10', 'GET UID with Le 00', '80 08 00 00 00', '9000', expLength: 10, info: true, group: CheckGroup.extra);
      await _check('X11', 'GET RESPONSE is not supported by the applet', '00 C0 00 00 00', '6D00', info: true, group: CheckGroup.extra);
      await _findCardSize();
    } finally {
      if (saved0 != null && saved1 != null && saved7 != null) {
        final restored = await _restore(saved0, saved1, saved7);
        _restoredText = restored ? 'yes' : 'NO, see the log for the saved bytes';
      } else {
        _restoreNotNeeded();
      }
      _sessionTimeRow('S1t', 'Tap 1 session time');
    }

    log.section('6. power off and on: tap 2, a new $phone session');
    if (!await _tap('S2', 'Tap 2: the $phone finds the card again')) {
      log.warn('The $phone did not find the card at tap 2. Its checks are listed as not sent.');
    }
    await _check('C32', 'READ right after the tap', '00 B0 00 00 02', '6986', info: true);
    await _check('C33', 'SELECT the applet', selectApplet, '9000');
    await _check('C34', 'READ before SELECT 3040', '00 B0 00 00 02', '6986');
    await _check('C35', 'SELECT EF 3040', '00 A4 00 00 02 30 40', '9000');
    if (saved0 != null) {
      await _check('C36', 'READ works again (restored bytes)', '00 B0 00 20 02', '9000', expData: Hex.of(saved0, 0x20, 2));
    } else {
      await _check('C36', 'READ works again (nothing was written)', '00 B0 00 20 02', '9000', expLength: 2);
    }
    const x15 = 'The card ID (GET UID) is the same after a new tap';
    final cardId = _cardId;
    if (cardId != null) {
      await _check('X15', x15, '80 08 00 00 0A', '9000', expData: Hex.of(cardId), group: CheckGroup.extra);
    } else {
      final r = await _exchange('80 08 00 00 0A', 'X15');
      _add('X15', 'FAIL', x15, '80 08 00 00 0A', 'the C02 card ID', r.ok ? 'C02 gave no card ID; now ${_got(r)}' : _notSentText(r),
          r.ms, CheckGroup.extra);
    }
    _sessionTimeRow('S2t', 'Tap 2 session time');
  }

  String get _discoveryText =>
      platform == PhonePlatform.iphone ? 'automatic SELECT of the AID list' : 'Android NDEF check, then IsoDep';

  String get _discoveryExpected => platform == PhonePlatform.iphone ? 'an AID answers 90 00' : 'an ISO-DEP card';

  String get _foundText =>
      platform == PhonePlatform.iphone ? 'initialSelectedAID ${s.initialSelectedAid}' : 'IsoDep (no AID needed)';

  String get _notFoundWhy => platform == PhonePlatform.iphone
      ? 'the iPhone did not find the card: no AID of the list answered 90 00'
      : 'Android did not find the card: it is not ISO-DEP';

  /// Why a command cannot reach the card in this session: the card is gone, or the phone never found it.
  String get _noCardText => _lost != null ? _lost!.message : _notFoundWhy;

  /// A tap. A reader or card error does not stop the test: the step fails and the error is kept.
  Future<bool> _tap(String id, String what) async {
    var found = false;
    String? error;
    try {
      found = await s.tap();
    } on CardException catch (e) {
      _lost ??= e;
      error = e.message;
      log.warn('The tap failed: ${e.message}');
    }
    if (found) _everFound = true;
    _add(id, found ? 'PASS' : 'FAIL', what, _discoveryText, _discoveryExpected,
        found ? _foundText : 'not found: ${error ?? _notFoundWhy}', 0, CheckGroup.steps);
    return found;
  }

  void _sessionTimeRow(String id, String what) {
    final expected = platform.hasSessionLimit ? 'under ${PhoneSession.iosLimitSeconds} s' : 'no limit on Android';
    if (!s.active || !s.detected) {
      _add(id, 'FAIL', what, '', expected, 'not run: $_noCardText', 0, CheckGroup.steps);
      return;
    }
    final t = s.elapsed;
    final ok = !platform.hasSessionLimit || t <= PhoneSession.iosLimitSeconds;
    _add(id, ok ? 'PASS' : 'FAIL', what, '', expected, '${t.toStringAsFixed(2)} s', 0, CheckGroup.steps);
  }

  /// Saves one area before anything is written. When it fails, the checks that write are not sent at all.
  Future<Uint8List?> _save(String apdu, int length, String area) async {
    final r = await _exchange(apdu, 'save $area');
    if (!_is(r, 0x9000) || r.response!.data.length != length) {
      _noWrites = 'could not save $area first (${r.ok ? r.short : _notSentText(r)}), so the test writes nothing';
      log.warn('Could not save $area (${r.short}). The checks that write are not sent, so nothing on the card changes; '
          'the other checks still run.');
      return null;
    }
    log.info('Saved $area: ${Hex.of(r.response!.data)}');
    return r.response!.data;
  }

  /// C12: reads all 128 blocks. A block that fails is counted and the next block is read.
  Future<void> _readWholeFile() async {
    const what = 'READ the whole file, 128 x 256 bytes';
    var total = 0, bad = 0;
    String? firstBad, notSent;
    final watch = Stopwatch()..start();
    for (var offset = 0; offset < fullSize; offset += 256) {
      final r = await _exchange('00 B0 ${h2(offset >> 8)} ${h2(offset & 0xFF)} 00', 'C12');
      if (!r.ok) {
        notSent = _notSentText(r);
        break;
      }
      if (_is(r, 0x9000)) total += r.response!.data.length;
      if (!_is(r, 0x9000) || r.response!.data.length != 256) {
        bad++;
        firstBad ??= '${h4(offset)} -> ${r.short}${_is(r, 0x9000) ? ' (${r.response!.data.length} bytes)' : ''}';
      }
    }
    final ok = notSent == null && bad == 0 && total == fullSize;
    final String got;
    if (notSent != null) {
      got = total == 0 ? notSent : '$total bytes, then $notSent';
    } else {
      got = bad == 0 ? '$total bytes' : '$total bytes; $bad of 128 blocks failed, the first at $firstBad';
    }
    _add('C12', ok ? 'PASS' : 'FAIL', what, '00 B0 xx 00 00', '32768 bytes', got, watch.elapsedMicroseconds / 1000,
        CheckGroup.forty);
  }

  /// X12: reads from 0000 until the card stops, 256 bytes at a time. A 6C xx answer is read again with Le = xx, so the
  /// exact size is found even when it is not a multiple of 256. Only 32768 bytes (offsets 0000-7FFF) passes.
  Future<void> _findCardSize() async {
    const what = 'Card size: read the whole card until it stops';
    const how = 'READ 256 at a time; 6C xx -> Le xx';
    var offset = 0, total = 0;
    var stop = 'offset 8000: the end of what READ BINARY can address';
    final watch = Stopwatch()..start();
    while (offset <= 0x7FFF) {
      final at = '${h2(offset >> 8)} ${h2(offset & 0xFF)}';
      final r = await _exchange('00 B0 $at 00', 'X12');
      if (!r.ok && offset == 0) {
        _add('X12', 'FAIL', what, how, '$fullSize bytes', _notSentText(r), 0, CheckGroup.extra);
        return;
      }
      if (_is(r, 0x9000)) {
        final n = r.response!.data.length;
        if (n == 0) {
          stop = 'an empty answer at ${h4(offset)}';
          break;
        }
        total += n;
        offset += n;
        continue;
      }
      if (r.ok && r.response!.sw1 == 0x6C) {
        final le = r.response!.sw2 == 0 ? 256 : r.response!.sw2;
        final r2 = await _exchange('00 B0 $at ${h2(le & 0xFF)}', 'X12');
        if (_is(r2, 0x9000) && r2.response!.data.isNotEmpty) {
          total += r2.response!.data.length;
          offset += r2.response!.data.length;
          continue;
        }
        stop = '${r2.ok ? r2.short : _notSentText(r2)} at ${h4(offset)}';
        break;
      }
      stop = '${r.ok ? r.short : _notSentText(r)} at ${h4(offset)}';
      break;
    }
    cardSize = total;
    cardSizeStop = stop;
    final ok = total == fullSize;
    final ms = watch.elapsedMicroseconds / 1000;
    final speed = ms > 0 ? ' in ${(ms / 1000).toStringAsFixed(2)} s' : '';
    _add('X12', ok ? 'PASS' : 'FAIL', what, how, '$fullSize bytes', '$total bytes$speed, stopped at $stop', ms, CheckGroup.extra);
    log.info('Card size: $total bytes (${ok ? 'PASS' : 'FAIL, only $fullSize passes'}); the reading stopped at $stop.');
  }

  /// C30: on a PC and on Android the applet answers 6A 86. On an iPhone, iOS blocks the SELECT because the AID is not
  /// in the app's list.
  Future<void> _selectUnknownAid() async {
    const apdu = '00 A4 04 00 05 A0 00 00 09 99';
    final r = await _exchange(apdu, 'C30');
    if (r.status == SendStatus.blocked) {
      _add('C30', 'BLOCKED', 'SELECT by an AID not on the card', apdu, 'PC 6A 86, iPhone: blocked',
          "not sent: iOS blocks a SELECT of an AID outside the app's list", 0, CheckGroup.forty);
      return;
    }
    _addResult('C30', 'SELECT by an AID not on the card', apdu, '6A86', null, -1, true, r, CheckGroup.forty);
  }

  Future<bool> _restore(Uint8List saved0, Uint8List saved1, Uint8List saved7) async {
    log.section('5. write the saved bytes back');
    _restoring = true;
    try {
      if (_lost != null) {
        // the card stopped answering on the way: power it again, so the saved bytes can still be written back
        try {
          await s.channel.fieldReset();
        } on CardException catch (e) {
          log.warn('The card cannot be powered again: ${e.message}');
        }
      }
      await _exchange(selectApplet, 'restore: SELECT applet');
      await _exchange('00 A4 00 00 02 30 40', 'restore: SELECT EF 3040');
      final a = _is(await _check('C37', 'restore 0000-003F', '00 D6 00 00 40 ${Hex.of(saved0)}', '9000'), 0x9000);
      final b = _is(await _check('C38', 'restore 7FC0-7FFF', '00 D6 7F C0 40 ${Hex.of(saved7)}', '9000'), 0x9000);
      final c = _lastPassed(await _check('C39', '  ...0000-003F equals the saved bytes', '00 B0 00 00 40', '9000', expData: Hex.of(saved0)));
      final d = _lastPassed(await _check('C40', '  ...7FC0-7FFF equals the saved bytes', '00 B0 7F C0 40', '9000', expData: Hex.of(saved7)));
      final e = _is(await _check('X13', 'restore 0100-01FE', '00 D6 01 00 FF ${Hex.of(saved1)}', '9000', group: CheckGroup.extra), 0x9000);
      final f = _lastPassed(await _check('X14', '  ...0100-01FE equals the saved bytes', '00 B0 01 00 FF', '9000',
          expData: Hex.of(saved1), group: CheckGroup.extra));
      final ok = a && b && c && d && e && f;
      if (!ok) _tellSavedBytes(saved0, saved1, saved7);
      return ok;
    } finally {
      _restoring = false;
      _viaSession = true; // tap 2 is a new phone session
    }
  }

  /// The restore rows when nothing was saved: nothing was written, so nothing is sent.
  void _restoreNotNeeded() {
    final why = s.detected && _lost == null ? 'not run: nothing was written, so there is nothing to write back' : 'not sent: $_noCardText';
    void row(String id, String what, String apdu, CheckGroup group) => _add(id, 'FAIL', what, apdu, '90 00', why, 0, group);
    row('C37', 'restore 0000-003F', '00 D6 00 00 40 <saved bytes>', CheckGroup.forty);
    row('C38', 'restore 7FC0-7FFF', '00 D6 7F C0 40 <saved bytes>', CheckGroup.forty);
    row('C39', '  ...0000-003F equals the saved bytes', '00 B0 00 00 40', CheckGroup.forty);
    row('C40', '  ...7FC0-7FFF equals the saved bytes', '00 B0 7F C0 40', CheckGroup.forty);
    row('X13', 'restore 0100-01FE', '00 D6 01 00 FF <saved bytes>', CheckGroup.extra);
    row('X14', '  ...0100-01FE equals the saved bytes', '00 B0 01 00 FF', CheckGroup.extra);
  }

  void _tellSavedBytes(Uint8List saved0, Uint8List saved1, Uint8List saved7) {
    log.warn('The card data was NOT fully written back. To do it by hand, send:');
    log.warn('00 A4 00 00 02 30 40');
    log.warn('00 D6 00 00 40 ${Hex.of(saved0)}');
    log.warn('00 D6 01 00 FF ${Hex.of(saved1)}');
    log.warn('00 D6 7F C0 40 ${Hex.of(saved7)}');
  }

  bool _lastPassed(SendResult? r) => r != null && rows.isNotEmpty && rows.last.result == 'PASS' && r.ok;

  static bool _is(SendResult? r, int sw) => r != null && r.ok && r.response!.sw == sw;

  /// Sends through the phone session, or straight to the reader when the session ended before the restore was done.
  /// A reader or card error does not stop the test: the command is "not sent" and the error is kept for the end.
  Future<SendResult> _exchange(String hex, String label) async {
    if (_viaSession && _restoring && !(s.active && s.detected && !s.expired)) {
      _viaSession = false;
      log.warn('The phone session is over, so the saved bytes are written back straight through the reader '
          '(outside the phone rules) to keep your data safe.');
    }
    final apdu = Hex.parse(hex);
    try {
      if (_viaSession) return await s.send(apdu, label);
      final watch = Stopwatch()..start();
      final response = ResponseApdu.fromRaw(await s.channel.transmit(apdu));
      final r = SendResult(apdu)
        ..sent = apdu
        ..response = response
        ..ms = watch.elapsedMicroseconds / 1000;
      log.exchange('$label (straight to the reader)', apdu, response, r.ms);
      return r;
    } on CardException catch (e) {
      if (_lost == null) {
        _lost = e;
        log.warn('The card stopped answering: ${e.message} The remaining checks are listed as not sent.');
      }
      return SendResult(apdu)
        ..status = SendStatus.noCard
        ..reason = e.message;
    }
  }

  /// Sends one check and adds its row. A check that writes (or reads back what a write put there) is not sent when
  /// the bytes could not be saved first; it is listed as FAIL "not run".
  Future<SendResult?> _check(String id, String what, String apdu, String expSw,
      {String? expData, int expLength = -1, bool info = false, bool write = false, CheckGroup group = CheckGroup.forty}) async {
    if (write && _noWrites != null && s.detected) {
      _add(id, 'FAIL', what, _shownApdu(apdu), _expectedText(expSw, expData, expLength), 'not run: $_noWrites', 0, group);
      return null;
    }
    final r = await _exchange(apdu, id);
    _addResult(id, what, apdu, expSw, expData, expLength, info, r, group);
    return r;
  }

  void _addResult(String id, String what, String apdu, String expSw, String? expData, int expLength, bool info, SendResult r,
      CheckGroup group) {
    final expected = _expectedText(expSw, expData, expLength);
    final shownApdu = _shownApdu(apdu);
    if (!r.ok) {
      _add(id, 'FAIL', what, shownApdu, expected, _notSentText(r), 0, group);
      return;
    }
    final resp = r.response!;
    final swOk = resp.swCompact == expSw;
    var ok = swOk;
    if (ok && expData != null) ok = Hex.of(resp.data) == expData;
    if (ok && expLength >= 0) ok = resp.data.length == expLength;
    // the error map tells the type of the answer; a right status word with wrong data is a data problem
    final answer = swOk && !ok ? wrongDataAnswer(resp.sw, expected, _got(r)) : explainAnswer(r.sent ?? r.typed, resp.sw);
    _add(id, ok ? 'PASS' : (info ? 'NOTE' : 'FAIL'), what, shownApdu, expected, _got(r), r.ms, group, answer: answer);
  }

  String _notSentText(SendResult r) {
    if (r.status == SendStatus.noCard) return 'not sent: $_noCardText';
    return 'not sent: ${r.reason}';
  }

  static String _got(SendResult r) => '${r.response!.swText} ${_dataText(r.response!.data)}'.trim();

  static String _expectedText(String expSw, String? expData, int expLength) =>
      '${expSw.substring(0, 2)} ${expSw.substring(2)}'
      '${expData != null ? ' + ${_short(expData)}' : ''}'
      '${expLength >= 0 ? ' + $expLength bytes' : ''}';

  static String _shownApdu(String apdu) => apdu.length > 60 ? '${apdu.substring(0, 44)}... (${(apdu.length + 1) ~/ 3} bytes)' : apdu;

  static String _short(String hex) => hex.length > 24 ? '${(hex.length + 1) ~/ 3} bytes' : hex;

  static String _dataText(Uint8List data) => data.length > 8 ? '${data.length} bytes' : Hex.of(data);

  void _add(String id, String result, String what, String apdu, String expected, String got, double ms, CheckGroup group,
      {AnswerType? answer}) {
    final row = CheckRow(id, result, what, apdu, expected, got, ms, group, answer: answer);
    rows.add(row);
    onRow?.call(row);
  }

  void _makeSummary() {
    String count(CheckGroup g, String result) => rows.where((r) => r.group == g && r.result == result).length.toString();
    final forty = rows.where((r) => r.group == CheckGroup.forty).length;
    final extra = rows.where((r) => r.group == CheckGroup.extra).length;
    final steps = rows.where((r) => r.group == CheckGroup.steps).length;
    final blocked = count(CheckGroup.forty, 'BLOCKED');
    final notSent = rows.where((r) => r.notSent && r.result == 'FAIL').length;
    final failedAnswers = rows.where((r) => r.result != 'PASS' && r.answer != null).map((r) => r.answer!).toList();
    final old = failedAnswers.where((a) => a.kind == AnswerKind.originalApplet).toList();
    final unexpected = failedAnswers.where((a) => a.kind == AnswerKind.unexpected).length;
    final findings = (old.map((a) => a.finding).where((f) => f.isNotEmpty).toSet().toList()..sort()).join(', ');
    final parts = <String>[
      if (!_everFound) 'The ${platform.short} never found the card, so no check reached it.',
      if (originalApplet) 'The card answers like the ORIGINAL applet (80 A4 returns the card ID instead of 6E 00).',
      '$forty checks: ${count(CheckGroup.forty, 'PASS')} of $forty passed, ${count(CheckGroup.forty, 'FAIL')} failed'
          '${blocked != '0' ? ', $blocked blocked by iOS (expected on an iPhone)' : ''}.',
      'Extra checks: ${count(CheckGroup.extra, 'PASS')} of $extra passed.',
      '${platform.short} steps: ${count(CheckGroup.steps, 'PASS')} of $steps OK.',
      if (cardSize != null) 'Card size: $cardSize bytes.',
      if (old.isNotEmpty)
        'Error map: ${old.length} of the answers that did not pass are what the ORIGINAL applet sends'
            '${findings.isEmpty ? '' : ' ($findings)'}.',
      if (unexpected > 0) 'Error map: $unexpected ${unexpected == 1 ? 'answer is' : 'answers are'} not in the map (UNEXPECTED).',
      if (notSent > 0) '$notSent ${notSent == 1 ? 'check' : 'checks'} could not reach the card (FAIL "not sent" or "not run").',
      'Card data written back: $_restoredText.',
    ];
    summary = parts.join(' ');
    log.section('SUMMARY: $summary');
  }
}
