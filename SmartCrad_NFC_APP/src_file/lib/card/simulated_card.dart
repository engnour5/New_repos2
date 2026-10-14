import 'dart:math';
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/hex.dart';
import '../gp/gp_keys.dart';
import 'card_channel.dart';
import 'simulated_isd.dart';

/// The electrical_electrometer applet (src as of 1 Oct 2026) on a minimal Java Card runtime, so the tool also works
/// without a reader. The applet is the default applet, as on the test card. Each check in [_process] follows the
/// Java code in the same order.
class SimulatedCard implements CardChannel {
  /// The card manager holds [keys], or else the default test key: the test card's own keys, from PyApduTool's
  /// config.ini, so the same keys open the simulator and the real card.
  SimulatedCard({this.delay = const Duration(milliseconds: 7), GpKeys? keys})
      : isd = SimulatedIsd(keys: _asOnTheTestCard(keys ?? GpKeys.defaultTestKey().keys)) {
    for (var i = 0; i < _nfcUid.length; i++) {
      _nfcUid[i] = _random.nextInt(256);
    }
    _nfcUid[0] = 0x04; // NXP
    isd.setChipSerial(Uint8List.fromList(List<int>.generate(4, (_) => _random.nextInt(256))),
        Uint8List.fromList(List<int>.generate(2, (_) => _random.nextInt(256))));
    // installing an applet runs its install(), which makes the card ID and the file anew
    isd.onInstall = (applet) => _memory[Hex.compact(applet.packageAid)] = _AppletMemory(_random);
    // the card arrives with the package loaded and its applet installed as the default one, as the test card is
    isd.preload(packageAid: packageAid, moduleAid: _appletAid, instanceAid: _appletAid);
    _fillDemoData(_memoryOf(packageAid));
  }

  /// Some content, so "Read card" has something to show: the card ID at 0000 (as on the real card), a text, a block
  /// of meter-like records, an all-FF block, and data in the last bytes up to 7FFF.
  static void _fillDemoData(_AppletMemory m) {
    m.main.setRange(0, m.cardUid.length, m.cardUid);
    final text = 'EMG METER CARD - SIMULATOR'.codeUnits;
    m.main.setRange(0x10, 0x10 + text.length, text);
    for (var i = 0; i < 0x200; i++) {
      m.main[0x1000 + i] = (i * 7 + 3) & 0xFF;
    }
    for (var i = 0; i < 0x100; i++) {
      m.main[0x2000 + i] = 0xFF;
    }
    for (var i = 0; i < 15; i++) {
      m.main[0x7FF0 + i] = 0xA0 + i;
    }
    m.extra[0] = 0x5A;
  }

  static const key = 'Simulated card (EMG applet logic, no reader needed)';

  static final _appletAid = Hex.parse('454D4730303030303030');

  /// The AID of the package the applet lives in, as the built CAP file has it ("EMG000000").
  static final packageAid = Hex.parse('45 4D 47 30 30 30 30 30 30');

  /// The card manager, so the burner screen can be used against the simulator too.
  final SimulatedIsd isd;

  /// The test card keeps its key set under key version 1; a key file that names a version keeps it.
  static GpKeys _asOnTheTestCard(GpKeys k) => k.keyVersion == 0 ? k.copyWith(keyVersion: 1) : k;
  static final _cardAtr = Hex.parse('3B8980010031C173C84000009093'); // the test card's contactless ATR
  static const _mainSize = 0x7FFF; // mainBuffer holds offsets 0000..7FFE
  static const _lastOffset = 0x7FFF; // offset 7FFF is kept in extraStorageBuffer[0]

  /// Time per command, so the screens move like with a real card. Zero in the tests.
  final Duration delay;

  final _random = Random();
  final _nfcUid = Uint8List(7);

  /// The applet's memory, per package. The EMG applet keeps its card ID and its file in static fields, which belong
  /// to the package, and its install() makes them anew: so a new install gives a new card ID and a file of 00, and
  /// an applet of another package has memory of its own.
  final _memory = <String, _AppletMemory>{};
  _AppletMemory? _current; // the memory of the selected applet

  bool _powered = false;
  bool _efSelected = false;
  int _selected = 0; // 0 = nothing (not powered yet), 1 = an applet, 2 = the card manager (ISD)

  _AppletMemory _memoryOf(Uint8List packageAid) =>
      _memory.putIfAbsent(Hex.compact(packageAid), () => _AppletMemory(_random));

  @override
  String get name => key;

  @override
  bool get isSimulated => true;

  @override
  Uint8List? get atr => _powered ? Uint8List.fromList(_cardAtr) : null;

  /// Takes this card off the reader and puts a different, untouched one on, the way an operator swaps cards.
  ///
  /// Everything the card held goes: a new NFC UID, the package and applet it left the factory with, and fresh applet
  /// memory. It lets the batch burner be run and tested without a tray of real cards.
  void insertNewCard() {
    _powered = false;
    _selected = 0;
    _efSelected = false;
    _current = null;
    _memory.clear();
    for (var i = 0; i < _nfcUid.length; i++) {
      _nfcUid[i] = _random.nextInt(256);
    }
    _nfcUid[0] = 0x04; // NXP
    // a different card means a different chip, as a new card off the tray would be
    isd.setChipSerial(Uint8List.fromList(List<int>.generate(4, (_) => _random.nextInt(256))),
        Uint8List.fromList(List<int>.generate(2, (_) => _random.nextInt(256))));
    isd.packages.clear();
    isd.applets.clear();
    isd.reset();
    isd.preload(packageAid: packageAid, moduleAid: _appletAid, instanceAid: _appletAid);
    _fillDemoData(_memoryOf(packageAid));
  }

  @override
  Future<void> connect() async {
    if (!_powered) _powerUp();
  }

  @override
  Future<void> fieldReset() async {
    await _wait(4);
    _powerUp();
  }

  @override
  Future<void> disconnect() async {
    _powered = false;
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<Uint8List?> getUid() async => _powered ? Uint8List.fromList(_nfcUid) : null;

  @override
  Future<Uint8List> transmit(Uint8List apdu) async {
    await _wait(1);
    return transmitNow(apdu);
  }

  Future<void> _wait(int times) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay * times);
  }

  void _powerUp() {
    _powered = true;
    isd.reset();
    _efSelected = false; // CLEAR_ON_RESET, and select() clears it too
    // the default applet is selected after every reset, whichever one holds the privilege; when none does, the card
    // manager is, as GlobalPlatform has it
    final applet = isd.defaultApplet;
    if (applet != null) {
      _selectApplet(applet);
    } else {
      _selected = 2;
      _current = null;
    }
  }

  void _selectApplet(SimApplet applet) {
    isd.reset(); // the card manager is no longer selected, which ends its secure channel
    _selected = 1;
    _current = _memoryOf(applet.packageAid);
    _efSelected = false; // select()
  }

  /// The answer of the card, without the delay.
  Uint8List transmitNow(Uint8List a) {
    if (!_powered) throw CardException('The simulated card is not powered.');
    if (a.length >= 2 && a[0] == 0xFF && a[1] == 0xCA) return Hex.concat([_nfcUid, _sw(0x9000)]); // PC/SC reader command
    if (a.length < 4) return _sw(0x6700);
    if (a.length > 5 && a[4] == 0x00) return _sw(0x6700); // extended APDU: the applet does not implement ExtendedLength

    // The card OS handles SELECT by AID. An unknown AID goes to the selected applet.
    if (a[0] == 0x00 && a[1] == 0xA4 && a[2] == 0x04) {
      final aid = _dataField(a);
      // any applet the card manager has installed answers to its own AID, whatever that AID is
      final applet = aid == null ? null : isd.appletWith(aid);
      if (applet != null) {
        _selectApplet(applet);
        return _sw(0x9000);
      }
      if (aid != null && Hex.same(aid, SimulatedIsd.aid)) {
        _selected = 2;
        _current = null;
        return isd.select();
      }
    }
    if (_selected == 2) return isd.process(a); // the card manager answers while it is selected
    final memory = _current;
    if (_selected != 1 || memory == null) return _sw(0x6999);
    return _process(a, memory);
  }

  Uint8List _process(Uint8List a, _AppletMemory m) {
    final cla = a[0], ins = a[1], p1 = a[2], p2 = a[3];
    final b4 = a.length > 4 ? a[4] : 0; // APDU buffer byte 4: Lc (or Le in a command without data)
    final received = _received(a); // what setIncomingAndReceive() returns
    switch (ins) {
      case 0xA4: // SELECT
        if (cla == 0x00) {
          if (p1 != 0x00 && p1 != 0x02) return _sw(0x6A86);
          if (b4 == 0 && received == 0 && p1 == 0x00) {
            _efSelected = false; // no data: select the MF
            return _sw(0x9000);
          }
          if (b4 != 2 || received != 2) return _sw(0x6700);
          final fid = (a[5] << 8) | a[6];
          if (fid == 0x3F00) {
            _efSelected = false;
          } else if (fid == 0x3040) {
            _efSelected = true;
          } else {
            return _sw(0x6A82);
          }
          return _sw(0x9000);
        }
        return _sw(0x6E00);

      case 0x08: // GET UID
        if (cla == 0x80) return Hex.concat([m.cardUid, _sw(0x9000)]);
        return _sw(0x6E00);

      case 0xD6: // UPDATE BINARY
        if (cla == 0x00) {
          if (!_efSelected) return _sw(0x6986);
          final total = b4;
          final offset = _offset(p1, p2);
          if (total == 0 || received != total) return _sw(0x6700);
          if (offset < 0) return _sw(0x6B00);
          if (total - 1 > _lastOffset - offset) return _sw(0x6700);
          if ((offset - 1) + total == _lastOffset) {
            m.main.setRange(offset, offset + total - 1, a, 5);
            m.extra[0] = a[5 + total - 1];
          } else {
            m.main.setRange(offset, offset + total, a, 5);
          }
          return _sw(0x9000);
        }
        return _sw(0x6E00);

      case 0xB0: // READ BINARY
        if (cla == 0x00) {
          if (!_efSelected) return _sw(0x6986);
          final offset = _offset(p1, p2);
          final ne = _le(a); // setOutgoing(): 256 for Le 00, 0 when there is no Le
          if (ne == 0) return _sw(0x6700);
          if (offset < 0) return _sw(0x6B00);
          final after = _lastOffset - offset;
          if (ne - 1 > after) return _sw(0x6C00 | (after + 1));
          final data = Uint8List(ne);
          if ((offset - 1) + ne == _lastOffset) {
            if (ne > 1) data.setRange(0, ne - 1, m.main, offset);
            data[ne - 1] = m.extra[0];
          } else {
            data.setRange(0, ne, m.main, offset);
          }
          return Hex.concat([data, _sw(0x9000)]);
        }
        return _sw(0x6E00);

      default:
        return _sw(0x6D00);
    }
  }

  /// P1 P2 as a Java short: P1 80 or more gives a negative offset.
  static int _offset(int p1, int p2) {
    final v = (p1 << 8) | p2;
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  static int _received(Uint8List a) {
    if (a.length <= 5) return 0; // no data field
    final lc = a[4];
    final available = a.length - 5;
    if (available == lc || available == lc + 1) return lc;
    return lc < available ? lc : available;
  }

  static int _le(Uint8List a) {
    if (a.length == 4) return 0; // no Le
    if (a.length == 5) return a[4] == 0 ? 256 : a[4]; // Le only
    final lc = a[4];
    if (a.length == 6 + lc) return a[a.length - 1] == 0 ? 256 : a[a.length - 1]; // data and Le
    return 0; // data, no Le
  }

  static Uint8List? _dataField(Uint8List a) {
    if (a.length <= 5) return null;
    final lc = a[4];
    return a.length >= 5 + lc ? Hex.sub(a, 5, lc) : null;
  }

  static Uint8List _sw(int sw) => Uint8List.fromList([sw >> 8, sw & 0xFF]);
}

/// What the EMG applet keeps: its card ID, which install() makes at random, and the 32 KB file, which starts as 00.
class _AppletMemory {
  _AppletMemory(Random random) {
    for (var i = 0; i < cardUid.length; i++) {
      cardUid[i] = random.nextInt(256);
    }
  }

  final cardUid = Uint8List(10);
  final main = Uint8List(SimulatedCard._mainSize);
  final extra = Uint8List(1);
}
