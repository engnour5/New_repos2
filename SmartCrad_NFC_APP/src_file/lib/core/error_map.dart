import 'dart:typed_data';

import 'applet.dart';
import 'hex.dart';
import 'status_words.dart';

/// The applet's error map (review\error_map.html, the "electrical_electrometer Error Map" page of 1 Oct 2026):
/// what each status word means, which check of the applet sends it, in the order the applet runs its checks, what the
/// meter should do, and what the ORIGINAL applet (the old .cap) answers instead. Line numbers refer to
/// src\electrical_electrometer\electrical_electrometer.java of 1 Oct 2026 (159 lines); F-numbers to the code review.
///
/// [explainAnswer] uses it to tell the type of every answer the card gives.

enum SwLevel { ok, warn, bad }

/// One status word of the map (section 1).
class SwEntry {
  const SwEntry(this.sw, this.level, this.iso, this.when, this.meter);

  final String sw; // "90 00", "6C xx"
  final SwLevel level;
  final String iso; // the ISO 7816-4 meaning
  final String when; // when the applet sends it
  final String meter; // what the meter should do
}

const errorMapSws = <SwEntry>[
  SwEntry('90 00', SwLevel.ok, 'Success', 'The command worked. READ returns the data, GET UID the 10-byte card ID.', 'Use the answer'),
  SwEntry('69 86', SwLevel.warn, 'Command not allowed, no current file',
      'READ or UPDATE before SELECT 3040, for example right after power-up', 'Send 00 A4 00 00 02 30 40, then repeat the command'),
  SwEntry('6C xx', SwLevel.warn, 'Wrong Le, xx bytes available', 'READ runs past 7FFF. xx is the number of bytes left.',
      'Send the same READ again with Le = xx'),
  SwEntry('67 00', SwLevel.warn, 'Wrong length',
      'SELECT data is not 2 bytes; UPDATE has no data, not all of it arrived, or it runs past 7FFF; READ has no Le', 'Fix Lc, Le or the data'),
  SwEntry('6B 00', SwLevel.warn, 'Wrong parameters P1-P2', 'READ or UPDATE with P1 of 80 or more, so the offset is past 7FFF',
      'Use offsets 0000 to 7FFF'),
  SwEntry('6A 82', SwLevel.warn, 'File not found', 'SELECT of a file other than 3F00 or 3040. The current file stays selected.',
      'Select 3040'),
  SwEntry('6A 86', SwLevel.warn, 'Incorrect P1-P2', 'SELECT with P1 other than 00 or 02', 'Select files by ID with P1 = 00'),
  SwEntry('6E 00', SwLevel.warn, 'Class not supported', 'Wrong CLA: 00 is needed for SELECT, READ and UPDATE, 80 for GET UID',
      'Fix the command'),
  SwEntry('6D 00', SwLevel.warn, 'Instruction not supported', 'INS is not A4, B0, D6 or 08', 'Fix the command'),
  SwEntry('6F 00', SwLevel.bad, 'No precise diagnosis', 'Only an unexpected crash. None of the tested commands produces it now.',
      'Report it as a bug'),
];

/// The entry of section 1 for a status word, or null when the map does not list it.
SwEntry? swEntryFor(int sw) {
  final text = (sw >> 8) == 0x6C ? '6C xx' : '${h2(sw >> 8)} ${h2(sw & 0xFF)}';
  for (final e in errorMapSws) {
    if (e.sw == text) return e;
  }
  return null;
}

enum MapCommand { select, getUid, update, read, other }

extension MapCommandText on MapCommand {
  String get title => switch (this) {
        MapCommand.select => 'SELECT',
        MapCommand.getUid => 'GET UID',
        MapCommand.update => 'UPDATE BINARY',
        MapCommand.read => 'READ BINARY',
        MapCommand.other => 'Any other instruction',
      };

  String get ins => switch (this) {
        MapCommand.select => 'INS A4 · CLA 00',
        MapCommand.getUid => 'INS 08 · CLA 80',
        MapCommand.update => 'INS D6 · CLA 00',
        MapCommand.read => 'INS B0 · CLA 00',
        MapCommand.other => 'line 155',
      };
}

/// One check of the map (section 2): the applet runs the checks of a command from top to bottom, and the first one that
/// fails decides the answer.
class MapCheck {
  const MapCheck(this.id, this.command, this.order, this.failsWhen, this.line, this.example, this.now, this.original, this.finding);

  final String id; // "READ 2"
  final MapCommand command;
  final String order; // "1".."5", or "OK"
  final String failsWhen;
  final int line; // line in src, 0 when the map gives none
  final String example;
  final String now; // the answer of the applet now
  final String original; // the answer of the original applet
  final String finding; // F-number of the code review, "" when the original answers the same

  bool get isOk => order == 'OK';
}

const errorMapChecks = <MapCheck>[
  MapCheck('SELECT 1', MapCommand.select, '1', 'CLA is not 00', 81, '80 A4 00 00 02 30 40', '6E 00', '90 00 + card ID', 'F1'),
  MapCheck('SELECT 2', MapCommand.select, '2', 'P1 is not 00 or 02', 60, '00 A4 04 00 02 30 40', '6A 86', '90 00, EF selected', 'F6'),
  MapCheck('SELECT 3', MapCommand.select, '3', 'Data is not exactly 2 bytes', 69, '00 A4 00 00 01 3F', '67 00', '90 00', 'F6'),
  MapCheck('SELECT 4', MapCommand.select, '4', 'File ID is not 3F00 or 3040', 77, '00 A4 00 00 02 2F 00', '6A 82, EF kept',
      '6D 00, EF dropped', 'F5'),
  MapCheck('SELECT OK', MapCommand.select, 'OK', 'File 3040 or 3F00', 0, '00 A4 00 00 02 30 40', '90 00', '90 00', ''),
  MapCheck('SELECT MF', MapCommand.select, 'OK', 'P1 00 with no data selects the MF', 0, '00 A4 00 00', '90 00', '6D 00', 'F6'),
  MapCheck('GET UID 1', MapCommand.getUid, '1', 'CLA is not 80', 88, '00 08 00 00 02 CA FE', '6E 00',
      '90 00, CA FE written to the file', 'F1'),
  MapCheck('GET UID OK', MapCommand.getUid, 'OK', 'P1, P2 and Le are not checked', 0, '80 08 00 00 0A', '90 00 + 10 bytes',
      '90 00 + 10 bytes', ''),
  MapCheck('UPDATE 1', MapCommand.update, '1', 'CLA is not 00', 118, '84 D6 00 00 02 11 22', '6E 00', '6D 00', 'F8'),
  MapCheck('UPDATE 2', MapCommand.update, '2', 'EF 3040 is not selected', 92, '00 D6 00 00 02 11 22', '69 86', '6D 00', 'F8'),
  MapCheck('UPDATE 3', MapCommand.update, '3', 'No data, or not all of it arrived', 102, '00 D6 00 00 02', '67 00, nothing written',
      '90 00, leftovers written', 'F2'),
  MapCheck('UPDATE 4', MapCommand.update, '4', 'P1 is 80 or more', 105, '00 D6 80 00 02 11 22', '6B 00', '6F 00', 'F7'),
  MapCheck('UPDATE 5', MapCommand.update, '5', 'Data would run past 7FFF', 108, '00 D6 7F FF 02 11 22', '67 00, nothing written',
      '6F 00', 'F7'),
  MapCheck('UPDATE OK', MapCommand.update, 'OK', '1 to 255 bytes, ending at 7FFF or before', 0, '00 D6 7F FE 02 11 22', '90 00',
      '90 00', ''),
  MapCheck('READ 1', MapCommand.read, '1', 'CLA is not 00', 153, '84 B0 00 00 10', '6E 00', '6D 00', 'F8'),
  MapCheck('READ 2', MapCommand.read, '2', 'EF 3040 is not selected', 122, '00 B0 00 00 10', '69 86', '6D 00', 'F8'),
  MapCheck('READ 3', MapCommand.read, '3', 'The command has no Le', 130, '00 B0 00 00', '67 00, nothing sent', '90 00 + 256 bytes',
      'F9'),
  MapCheck('READ 4', MapCommand.read, '4', 'P1 is 80 or more', 134, '00 B0 80 00 10', '6B 00', '6F 00', 'F7'),
  MapCheck('READ 5', MapCommand.read, '5', 'Le runs past 7FFF', 138, '00 B0 7F F8 10', '6C 08', '6F 00', 'F7'),
  MapCheck('READ OK', MapCommand.read, 'OK', 'Le 01 to FF, or 00 for 256 bytes, ending at 7FFF or before', 0, '00 B0 7F F8 08',
      '90 00 + 8 bytes', '90 00 + 8 bytes', ''),
  MapCheck('OTHER', MapCommand.other, '1', 'INS is not A4, 08, D6 or B0', 155, '00 CA 00 00 00', '6D 00', '6D 00', ''),
];

const errorMapNotes = <String>[
  'After every power-up, and every time the applet is selected, no file is selected. The first READ or UPDATE needs '
      'SELECT 3040, or it answers 69 86.',
  'A failed SELECT (6A 82, 6A 86 or 67 00) keeps the file that was selected before.',
  'Le 00 means 256 bytes. 00 B0 7F 00 00 reads the last 256 bytes of the file, up to 7FFF.',
  "SELECT by this applet's AID is answered by the card OS. A SELECT by an AID that is not on the card is passed to the "
      'selected applet, so this applet answers it with 6A 86.',
  'On a T=0 reader, 6C xx may be handled by the reader itself, which repeats the READ with the right Le.',
];

/// The applet's AID: a SELECT of it is answered by the card OS. Callers that know which applet is on the card pass
/// it in, so the explanation still fits after another applet is burned.
final _defaultAppletAid = Hex.parse(AppletAid.defaultHex);

MapCheck _check(String id) => errorMapChecks.firstWhere((c) => c.id == id);

// ------------------------------------------------------------------ the type of an answer

enum AnswerKind {
  /// What the applet answers when the command is right.
  success,

  /// An error the applet sends on purpose: one of the checks of the map.
  appletError,

  /// Not what the applet answers now, but what the ORIGINAL applet (the old .cap) answers.
  originalApplet,

  /// The status word is right, but the data is not what was expected.
  wrongData,

  /// Neither the applet nor the original applet answers this.
  unexpected,
}

class AnswerType {
  const AnswerType(this.kind, this.sw, this.title, this.detail, {this.check, this.finding = ''});

  final AnswerKind kind;
  final int sw;
  final String title;
  final String detail;
  final MapCheck? check; // the check of the map that sends this answer (the applet's own check)
  final String finding; // F-number when the answer is the original applet's

  /// A short label for tables: "OK", "READ 2", "OLD F8", "DATA", "UNEXPECTED".
  String get tag => switch (kind) {
        AnswerKind.success => 'OK',
        AnswerKind.appletError => check?.id ?? 'ERROR',
        AnswerKind.originalApplet => finding.isEmpty ? 'OLD' : 'OLD $finding',
        AnswerKind.wrongData => 'DATA',
        AnswerKind.unexpected => 'UNEXPECTED',
      };

  /// One line for the log and the reports.
  String get text => detail.isEmpty ? title : '$title. $detail';

  /// A few words for the log: "Success", "READ 2: EF 3040 is not selected", "ORIGINAL applet answer (F8): ...".
  String get short => switch (kind) {
        AnswerKind.success => swMeaning(sw),
        AnswerKind.appletError => '${check!.id}: ${check!.failsWhen}',
        _ => title,
      };
}

/// Tells the type of the card's answer [sw] to [command], from the error map: one of the applet's checks, the answer
/// of the ORIGINAL applet (with its F-number), or an unexpected answer. The applet's state (is EF 3040 selected?) is
/// not known, so both states are tried.
AnswerType explainAnswer(Uint8List command, int sw, {Uint8List? appletAid}) {
  final swText = '${h2(sw >> 8)} ${h2(sw & 0xFF)}';
  final entry = swEntryFor(sw);
  if (command.length < 4) {
    return AnswerType(AnswerKind.unexpected, sw, 'Unexpected answer $swText: ${swMeaning(sw)}', 'The command is shorter than 4 bytes.');
  }
  final now = _newApplet(command, appletAid ?? _defaultAppletAid);
  for (final a in now) {
    if (a.sw != sw) continue;
    final c = a.check;
    if (sw == 0x9000) {
      return AnswerType(AnswerKind.success, sw, a.note.isNotEmpty ? a.note : '${c.command.title} OK: ${c.failsWhen}', '', check: c);
    }
    final where = c.line > 0 ? 'src line ${c.line}' : 'error map';
    final why = a.note.isNotEmpty ? '${a.note}. ' : '';
    return AnswerType(
      AnswerKind.appletError,
      sw,
      '${c.command.title} check ${c.order}: ${c.failsWhen}',
      '$why$swText = ${entry?.iso ?? swMeaning(sw)} ($where). The meter should: ${entry?.meter ?? 'fix the command'}.',
      check: c,
    );
  }
  final expected = _expectedText(now);
  for (final a in _originalApplet(command)) {
    if (a.sw != sw) continue;
    return AnswerType(
      AnswerKind.originalApplet,
      sw,
      'ORIGINAL applet answer${a.finding.isEmpty ? '' : ' (${a.finding})'}: ${a.note}',
      'The applet now answers $expected.',
      finding: a.finding,
    );
  }
  return AnswerType(
    AnswerKind.unexpected,
    sw,
    'Unexpected answer $swText: ${entry?.iso ?? swMeaning(sw)}',
    'Neither the applet nor the original applet answers this command with $swText. The applet now answers $expected.'
        '${sw == 0x6F00 ? ' The meter should report it as a bug.' : ''}',
  );
}

/// The type of an answer whose status word is right but whose data is not.
AnswerType wrongDataAnswer(int sw, String expected, String got) => AnswerType(
    AnswerKind.wrongData, sw, 'The status word is right, but the data is different', 'Expected $expected, got $got.');

String _expectedText(List<_Answer> now) {
  if (now.isEmpty) return '-';
  String one(_Answer a) => '${h2(a.sw >> 8)} ${h2(a.sw & 0xFF)} (${a.check.id})';
  if (!now.any((a) => a.efNotSelected)) return now.map(one).join(' or ');
  final notSelected = now.where((a) => a.efNotSelected).map(one).join(' or ');
  final selected = now.where((a) => !a.efNotSelected).map(one).join(' or ');
  return '$notSelected when no file is selected, $selected when EF 3040 is selected';
}

class _Answer {
  const _Answer(this.sw, this.check, {this.note = '', this.efNotSelected = false});

  final int sw;
  final MapCheck check;
  final String note;
  final bool efNotSelected;
}

class _OldAnswer {
  const _OldAnswer(this.sw, this.note, this.finding);

  final int sw;
  final String note;
  final String finding;
}

/// The bytes a command brings in its data field (what setIncomingAndReceive() returns), as the applet sees them.
int _received(Uint8List a) {
  if (a.length <= 5) return 0;
  final lc = a[4], available = a.length - 5;
  if (available == lc || available == lc + 1) return lc;
  return lc < available ? lc : available;
}

/// Le as the card OS gives it to the applet: 256 for Le 00, 0 when the command has no Le.
int _le(Uint8List a) {
  if (a.length == 4) return 0;
  if (a.length == 5) return a[4] == 0 ? 256 : a[4];
  final lc = a[4];
  if (a.length == 6 + lc) return a[a.length - 1] == 0 ? 256 : a[a.length - 1];
  return 0;
}

int _offset(Uint8List a) {
  final v = (a[2] << 8) | a[3];
  return v >= 0x8000 ? v - 0x10000 : v;
}

int _short(int v) => (v & 0xFFFF) >= 0x8000 ? (v & 0xFFFF) - 0x10000 : v & 0xFFFF;

bool _selectByAid(Uint8List a) => (a[0] & 0xFC) == 0x00 && a[1] == 0xA4 && a[2] == 0x04;

/// What the applet answers now (src of 1 Oct 2026), for both states of EF 3040.
List<_Answer> _newApplet(Uint8List a, Uint8List appletAid) {
  final cla = a[0], ins = a[1], p1 = a[2];
  final p3 = a.length > 4 ? a[4] : 0; // Lc, or Le in a command without data
  final received = _received(a);
  if (_selectByAid(a)) {
    final aid = received > 0 ? Hex.sub(a, 5, received) : Uint8List(0);
    if (Hex.same(aid, appletAid)) {
      return [_Answer(0x9000, _check('SELECT OK'), note: 'SELECT of the applet by its AID: the card OS selected the applet')];
    }
    return [
      _Answer(0x6A86, _check('SELECT 2'),
          note: 'This AID is not on the card, so the card OS passed the SELECT to the applet, which selects files by ID only'),
      if (received >= 5 && received <= 16)
        _Answer(0x9000, _check('SELECT OK'), note: 'SELECT by AID: an applet on the card has this AID, and the card OS selected it'),
    ];
  }
  switch (ins) {
    case 0xA4:
      if (cla != 0x00) return [_Answer(0x6E00, _check('SELECT 1'))];
      if (p1 != 0x00 && p1 != 0x02) return [_Answer(0x6A86, _check('SELECT 2'))];
      if (p3 == 0 && received == 0 && p1 == 0x00) return [_Answer(0x9000, _check('SELECT MF'))];
      if (p3 != 2 || received != 2) return [_Answer(0x6700, _check('SELECT 3'))];
      final fid = (a[5] << 8) | a[6];
      if (fid == 0x3F00 || fid == 0x3040) return [_Answer(0x9000, _check('SELECT OK'))];
      return [_Answer(0x6A82, _check('SELECT 4'))];
    case 0x08:
      return [cla == 0x80 ? _Answer(0x9000, _check('GET UID OK')) : _Answer(0x6E00, _check('GET UID 1'))];
    case 0xD6:
      if (cla != 0x00) return [_Answer(0x6E00, _check('UPDATE 1'))];
      final offset = _offset(a);
      final _Answer selected;
      if (p3 == 0 || received != p3) {
        selected = _Answer(0x6700, _check('UPDATE 3'));
      } else if (offset < 0) {
        selected = _Answer(0x6B00, _check('UPDATE 4'));
      } else if (p3 - 1 > 0x7FFF - offset) {
        selected = _Answer(0x6700, _check('UPDATE 5'));
      } else {
        selected = _Answer(0x9000, _check('UPDATE OK'));
      }
      return [_Answer(0x6986, _check('UPDATE 2'), efNotSelected: true), selected];
    case 0xB0:
      if (cla != 0x00) return [_Answer(0x6E00, _check('READ 1'))];
      final offset = _offset(a), le = _le(a);
      final _Answer selected;
      if (le == 0) {
        selected = _Answer(0x6700, _check('READ 3'));
      } else if (offset < 0) {
        selected = _Answer(0x6B00, _check('READ 4'));
      } else if (le - 1 > 0x7FFF - offset) {
        final left = 0x7FFF - offset + 1;
        selected = _Answer(0x6C00 | (left & 0xFF), _check('READ 5'), note: 'Only $left bytes are left after ${h4(offset)}');
      } else {
        selected = _Answer(0x9000, _check('READ OK'));
      }
      return [_Answer(0x6986, _check('READ 2'), efNotSelected: true), selected];
    default:
      return [_Answer(0x6D00, _check('OTHER'))];
  }
}

/// What the ORIGINAL applet answers (review\gas_electrometer_original.java), for both states of its file flag. Its
/// cases fall through, nothing checks a length, and an array copy outside mainBuffer ends in 6F 00. The real card
/// reads 00 after the command bytes.
List<_OldAnswer> _originalApplet(Uint8List a) {
  final cla = a[0], ins = a[1], p1 = a[2];
  final p3 = a.length > 4 ? a[4] : 0;
  final received = _received(a);
  final d5 = a.length > 5 ? a[5] : 0, d6 = a.length > 6 ? a[6] : 0;
  final start = switch (ins) { 0xA4 => 0, 0x08 => 1, 0xD6 => 2, 0xB0 => 3, _ => 4 };
  const noFile = 'no file selected, and the ORIGINAL applet answers 6D 00 instead of 69 86';
  if (start <= 0 && cla == 0x00) {
    final known = (d5 == 0x3F && d6 == 0x00) || (d5 == 0x30 && d6 == 0x40);
    if (known) {
      if (p1 == 0x04) {
        return [const _OldAnswer(0x9000, 'the AID is not on the card, so the ORIGINAL applet got the SELECT and took its first 2 bytes as a file ID', 'F6')];
      }
      if (p1 != 0x00 && p1 != 0x02) return [const _OldAnswer(0x9000, 'the ORIGINAL applet does not check P1', 'F6')];
      if (p3 != 2 || received != 2) return [const _OldAnswer(0x9000, 'the ORIGINAL applet does not check the data length', 'F6')];
      return [const _OldAnswer(0x9000, 'the same answer as now', '')];
    }
    if (p1 == 0x04) {
      return [
        const _OldAnswer(0x6D00,
            'this AID is not on the card, so the card OS passed the SELECT to the default applet; the ORIGINAL applet takes '
                'the AID as a file ID it does not know and answers 6D 00',
            'F5')
      ];
    }
    if (p3 == 0 && received == 0) {
      return [const _OldAnswer(0x6D00, 'SELECT with no data: the ORIGINAL applet does not select the MF and answers 6D 00', 'F6')];
    }
    return [const _OldAnswer(0x6D00, 'file not found: the ORIGINAL applet answers 6D 00 and drops the selected file', 'F5')];
  }
  if (start <= 1 && cla == 0x80) {
    if (ins == 0x08) return [const _OldAnswer(0x9000, 'the same answer as now', '')];
    return [const _OldAnswer(0x9000, 'CLA 80: the ORIGINAL applet falls through to GET UID and sends the card ID', 'F1')];
  }
  if (start <= 2 && cla == 0x00) {
    final offset = _offset(a), total = p3;
    final last = _short(offset - 1 + total) == 0x7FFF;
    final fits = last ? offset >= 0 && total >= 1 : offset >= 0 && offset + total <= 0x7FFF;
    final _OldAnswer selected;
    if (!fits) {
      selected = const _OldAnswer(0x6F00, 'the ORIGINAL applet does not check the offset or the length, so the write runs outside the file: 6F 00', 'F7');
    } else if (ins == 0x08) {
      selected = const _OldAnswer(0x9000, 'GET UID with CLA 00: the ORIGINAL applet falls through to UPDATE and writes the data to the file', 'F1');
    } else if (total == 0 || received != total) {
      selected = const _OldAnswer(0x9000, 'UPDATE without (all) its data: the ORIGINAL applet writes leftover bytes', 'F2');
    } else {
      selected = const _OldAnswer(0x9000, 'the same answer as now', '');
    }
    return [const _OldAnswer(0x6D00, noFile, 'F8'), selected];
  }
  if (start <= 3 && cla == 0x00) {
    final offset = _offset(a), total = p3 == 0 ? 256 : p3;
    final last = _short(offset - 1 + total) == 0x7FFF;
    final fits = last ? offset >= 0 : offset >= 0 && offset + total <= 0x7FFF;
    final _OldAnswer selected;
    if (!fits) {
      selected = const _OldAnswer(0x6F00, 'the ORIGINAL applet does not check the offset or Le, so the read runs outside the file: 6F 00', 'F7');
    } else if (a.length == 4) {
      selected = const _OldAnswer(0x9000, 'READ with no Le: the ORIGINAL applet sends 256 bytes', 'F9');
    } else {
      selected = const _OldAnswer(0x9000, 'the same answer as now', '');
    }
    return [const _OldAnswer(0x6D00, noFile, 'F8'), selected];
  }
  if (start <= 3) {
    return [const _OldAnswer(0x6D00, 'wrong CLA: the ORIGINAL applet answers 6D 00 instead of 6E 00', 'F8')];
  }
  return [const _OldAnswer(0x6D00, 'the same answer as now', '')];
}
