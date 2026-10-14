import 'dart:math';
import 'dart:typed_data';

import '../core/hex.dart';
import '../gp/gp_keys.dart';
import '../gp/scp02.dart';

/// One package on the simulated card, with the applets it defines.
class SimPackage {
  SimPackage(this.aid, this.modules);

  final Uint8List aid;
  final List<Uint8List> modules;
}

/// One installed applet instance on the simulated card.
class SimApplet {
  SimApplet(this.aid, this.packageAid, this.privileges);

  final Uint8List aid;
  final Uint8List packageAid;
  int privileges;
  int lifeCycle = 0x07; // SELECTABLE
}

/// The Issuer Security Domain of the simulated card: the card manager side of GlobalPlatform.
///
/// It speaks SCP02 the way the test card does, so the burner screen can be built and tested without a reader and
/// without spending a real card's authentication tries.
class SimulatedIsd {
  SimulatedIsd({GpKeys? keys, Random? random})
      // the simulated card passes its key set in; on its own, this holds the factory key under key version 1
      : keys = keys ?? GpKeys.factoryKey().copyWith(keyVersion: 1),
        _random = random ?? Random();

  static final aid = Hex.parse('A000000151000000');
  static final _fci = Hex.parse('6F108408A000000151000000A5049F6501FF');

  /// The card-manager commands. Every one of them needs the secure channel.
  static const _managementIns = {0x82, 0xD8, 0xE2, 0xE4, 0xE6, 0xE8, 0xF0, 0xF2};

  /// What the chip maker burned in, the 42 bytes of CPLC. The shape is the test card's own, read off it on
  /// 4 Oct 2026; only the serial number and the batch differ from card to card, as on real ones.
  final cplc = Hex.parse('47 90 D3 21 47 00 00 00 00 00 31 60  00 00 00 00  00 00  '
      '00 00 00 00 00 00 00 00 14 70 6A 35 38 37 32 38 00 00 00 00 00 00 00 00');

  /// Gives this card its own chip serial and batch, so two simulated cards are told apart as real ones are.
  void setChipSerial(Uint8List serial, Uint8List batch) {
    cplc.setRange(12, 16, serial);
    cplc.setRange(16, 18, batch);
  }

  final GpKeys keys;
  final Random _random;

  final List<SimPackage> packages = [];
  final List<SimApplet> applets = [];

  /// Called when an applet instance is made, which is when a card runs the applet's install().
  void Function(SimApplet applet)? onInstall;

  /// The most bytes one GET STATUS answer carries. What does not fit follows a 63 10, with "get next" (P2 01).
  int statusPageBytes = 0xF0;

  int sequenceCounter = 0x0020;
  Scp02Session? _session;
  Uint8List _icv = Uint8List(8);
  Uint8List _hostChallenge = Uint8List(8);
  Uint8List _cardChallenge = Uint8List(8); // the counter and the card's random bytes, as they go in the response

  /// What is being loaded right now, between INSTALL [for load] and the last LOAD block.
  final List<int> _loading = [];
  Uint8List? _loadingAid;
  int _nextBlock = 0;

  /// The GET STATUS entries the last answer had no room for.
  List<List<int>> _statusLeft = [];

  bool get open => _session?.open ?? false;

  SimApplet? appletWith(Uint8List aid) => applets.where((a) => Hex.same(a.aid, aid)).firstOrNull;

  bool hasApplet(Uint8List aid) => appletWith(aid) != null;

  SimApplet? get defaultApplet => applets.where((a) => a.privileges & 0x04 != 0).firstOrNull;

  /// Puts a package and its installed applet on the card, the way a card arrives already loaded.
  void preload({required Uint8List packageAid, required Uint8List moduleAid, required Uint8List instanceAid, int privileges = 0x04}) {
    packages.add(SimPackage(packageAid, [moduleAid]));
    final applet = SimApplet(instanceAid, packageAid, privileges);
    applets.add(applet);
    onInstall?.call(applet);
  }

  void reset() {
    _session = null;
    _icv = Uint8List(8);
    _loading.clear();
    _loadingAid = null;
    _nextBlock = 0;
    _statusLeft = [];
  }

  static Uint8List _sw(int sw) => Uint8List.fromList([sw >> 8, sw & 0xFF]);

  /// The answer to SELECT of the card manager's own AID.
  Uint8List select() {
    reset();
    return Hex.concat([_fci, _sw(0x9000)]);
  }

  /// Everything the card manager answers while it is selected, which after a power-up is when no applet is the
  /// default one.
  Uint8List process(Uint8List a) {
    if (a.length < 4) return _sw(0x6700);
    final ins = a[1];
    if (ins == 0x50) return _initializeUpdate(a);
    if (ins == 0xA4) return _sw(0x6A82); // SELECT of something this card does not have
    if (ins == 0xCA) {
      // GET DATA. The test card answers CPLC with the card manager simply selected, outside any secure channel.
      if (a[2] == 0x9F && a[3] == 0x7F) return Hex.concat([[0x9F, 0x7F, cplc.length], cplc, _sw(0x9000)]);
      return _sw(0x6A88); // this card manager keeps none of the other data objects
    }
    if (!_managementIns.contains(ins)) return _sw(0x6D00);

    // every card-manager command needs the secure channel and must carry its C-MAC
    final session = _session;
    if (session == null || a[0] & 0x04 == 0) return _sw(0x6982); // security status not satisfied
    if (a.length < 5 || a[4] < 8 || a.length < 5 + a[4]) return _sw(0x6700);

    final lc = a[4];
    final body = Hex.sub(a, 5, lc - 8);
    final mac = Hex.sub(a, 5 + lc - 8, 8);
    final expected = computeCMac(session.sMac, _icv, Hex.concat([Hex.sub(a, 0, 5), body]));
    if (!Hex.same(mac, expected)) {
      reset(); // a wrong C-MAC ends the secure channel
      return _sw(0x6982);
    }
    _icv = desEcbBlock(Uint8List.sublistView(session.sMac, 0, 8), mac);

    if (ins == 0x82) return _externalAuthenticate(body);
    if (!session.open) return _sw(0x6982);
    return switch (ins) {
      0xF2 => _getStatus(a[2], a[3], body),
      0xE4 => _delete(a[3], body),
      0xE6 => _install(a[2], body),
      0xE8 => _load(a[2], a[3], body),
      _ => _sw(0x6D00),
    };
  }

  Uint8List _initializeUpdate(Uint8List a) {
    if (a.length < 13 || a[4] != 8) return _sw(0x6700);
    if (a[2] != 0 && a[2] != keys.keyVersion) return _sw(0x6A88); // no such key version
    reset();
    _hostChallenge = Hex.sub(a, 5, 8);
    _cardChallenge = Uint8List.fromList([
      sequenceCounter >> 8,
      sequenceCounter & 0xFF,
      ...List<int>.generate(6, (_) => _random.nextInt(256)),
    ]);
    final session = Scp02Session.fromStaticKeys(keys.enc, keys.mac, keys.dek, sequenceCounter);
    _session = session;
    return Hex.concat([
      List<int>.filled(10, 0x11), // key diversification data
      [keys.keyVersion, 0x02], // key version and "this is SCP02"
      _cardChallenge,
      cardCryptogram(session.sEnc, _hostChallenge, _cardChallenge),
      _sw(0x9000),
    ]);
  }

  Uint8List _externalAuthenticate(Uint8List body) {
    final session = _session!;
    if (body.length != 8) return _sw(0x6700);
    if (!Hex.same(body, hostCryptogram(session.sEnc, _cardChallenge, _hostChallenge))) {
      _session = null;
      return _sw(0x6300); // authentication failed
    }
    session.open = true;
    sequenceCounter++;
    return _sw(0x9000);
  }

  Uint8List _getStatus(int p1, int p2, Uint8List body) {
    if (body.length < 2 || body[0] != 0x4F) return _sw(0x6A80);
    if (p2 & 0x01 != 0) return _statusLeft.isEmpty ? _sw(0x6A88) : _statusPage(); // "get next"
    final entries = <List<int>>[];
    switch (p1) {
      case 0x80:
        entries.add([aid.length, ...aid, 0x0F, 0x80]); // SECURED, Security Domain
      case 0x40:
        for (final app in applets) {
          entries.add([app.aid.length, ...app.aid, app.lifeCycle, app.privileges]);
        }
      case 0x20:
        for (final p in packages) {
          entries.add([p.aid.length, ...p.aid, 0x01, 0x00]);
        }
      case 0x10:
        for (final p in packages) {
          entries.add([p.aid.length, ...p.aid, 0x01, 0x00, p.modules.length, for (final m in p.modules) ...[m.length, ...m]]);
        }
      default:
        return _sw(0x6A86);
    }
    if (entries.isEmpty) return _sw(0x6A88);
    _statusLeft = entries;
    return _statusPage();
  }

  /// As many entries as fit in one answer, whole. 63 10 says that more follow.
  Uint8List _statusPage() {
    final out = <int>[];
    var n = 0;
    while (n < _statusLeft.length && (n == 0 || out.length + _statusLeft[n].length <= statusPageBytes)) {
      out.addAll(_statusLeft[n++]);
    }
    _statusLeft = _statusLeft.sublist(n);
    return Hex.concat([out, _sw(_statusLeft.isEmpty ? 0x9000 : 0x6310)]);
  }

  Uint8List _delete(int p2, Uint8List body) {
    if (body.length < 2 || body[0] != 0x4F || body.length < 2 + body[1]) return _sw(0x6A80);
    final target = Hex.sub(body, 2, body[1]);
    final withRelated = p2 & 0x80 != 0;

    final applet = appletWith(target);
    if (applet != null) {
      applets.remove(applet);
      return _sw(0x9000);
    }
    final package = packages.where((x) => Hex.same(x.aid, target)).firstOrNull;
    if (package == null) return _sw(0x6A88);
    final fromPackage = applets.where((x) => Hex.same(x.packageAid, target)).toList();
    if (fromPackage.isNotEmpty && !withRelated) {
      return _sw(0x6985); // its applets are still installed: a plain delete is refused
    }
    applets.removeWhere((x) => Hex.same(x.packageAid, target));
    packages.remove(package);
    return _sw(0x9000);
  }

  Uint8List _install(int p1, Uint8List body) {
    if (p1 == 0x02) {
      // INSTALL [for load]
      if (body.isEmpty || body.length < 1 + body[0]) return _sw(0x6A80);
      final packageAid = Hex.sub(body, 1, body[0]);
      if (packages.any((p) => Hex.same(p.aid, packageAid))) return _sw(0x6A88); // already there: delete it first
      _loadingAid = packageAid;
      _loading.clear();
      _nextBlock = 0;
      return _sw(0x9000);
    }
    if (p1 & 0x0C == 0x0C) {
      // INSTALL [for install and make selectable]
      var p = 0;
      Uint8List? next() {
        if (p >= body.length || p + 1 + body[p] > body.length) return null;
        final v = Hex.sub(body, p + 1, body[p]);
        p += 1 + body[p];
        return v;
      }

      final packageAid = next(), moduleAid = next(), instanceAid = next(), privileges = next();
      if (packageAid == null || moduleAid == null || instanceAid == null || privileges == null) return _sw(0x6A80);
      final package = packages.where((x) => Hex.same(x.aid, packageAid)).firstOrNull;
      if (package == null) return _sw(0x6A88);
      if (!package.modules.any((m) => Hex.same(m, moduleAid))) return _sw(0x6A88);
      if (hasApplet(instanceAid)) return _sw(0x6A88); // that AID is taken
      final wanted = privileges.isEmpty ? 0 : privileges[0];
      // a card allows only one default selected applet: it refuses rather than taking the privilege off the other one
      // (the real test card answers 69 85 here)
      if (wanted & 0x04 != 0 && applets.any((a) => a.privileges & 0x04 != 0)) return _sw(0x6985);
      final applet = SimApplet(instanceAid, packageAid, wanted);
      applets.add(applet);
      onInstall?.call(applet); // the applet's install() runs now
      return _sw(0x9000);
    }
    return _sw(0x6A86);
  }

  Uint8List _load(int p1, int blockNumber, Uint8List body) {
    final loadingAid = _loadingAid;
    if (loadingAid == null) return _sw(0x6985); // no INSTALL [for load] came first
    if (blockNumber != _nextBlock) {
      // a block out of order: the card gives up on the whole load
      _loading.clear();
      _loadingAid = null;
      return _sw(0x6A86);
    }
    _nextBlock = (_nextBlock + 1) & 0xFF;
    _loading.addAll(body);
    if (p1 & 0x80 == 0) return _sw(0x9000);

    // the last block: the whole Load File Data Block is here
    final all = Uint8List.fromList(_loading);
    _loading.clear();
    _loadingAid = null;
    final components = _components(all);
    // Header.cap: tag, size(2), magic(4), CAP minor and major, flags, package minor and major, AID length, AID
    final header = components?[0x01];
    if (components == null || header == null || header.length < 13 || header.length < 13 + header[12]) {
      return _sw(0x6A80);
    }
    if (!Hex.same(Hex.sub(header, 13, header[12]), loadingAid)) return _sw(0x6A80); // not the package announced
    packages.add(SimPackage(loadingAid, _appletAids(components[0x03])));
    return _sw(0x9000);
  }

  /// The components of a Load File Data Block by tag: C4, a BER length that has to match what came, then the
  /// components, each a tag and a 2-byte size. Null when the block is not built that way.
  static Map<int, Uint8List>? _components(Uint8List block) {
    if (block.length < 2 || block[0] != 0xC4) return null;
    var p = 2, length = block[1];
    if (length == 0x81 && block.length > 2) {
      length = block[2];
      p = 3;
    } else if (length == 0x82 && block.length > 3) {
      length = (block[2] << 8) | block[3];
      p = 4;
    } else if (length >= 0x80) {
      return null;
    }
    if (p + length != block.length) return null;
    final out = <int, Uint8List>{};
    while (p < block.length) {
      if (p + 3 > block.length) return null;
      final size = (block[p + 1] << 8) | block[p + 2];
      if (p + 3 + size > block.length) return null;
      out[block[p]] = Hex.sub(block, p, 3 + size);
      p += 3 + size;
    }
    return out;
  }

  /// The applet AIDs of Applet.cap: tag, size(2), count, then for each an AID length, the AID and a 2-byte offset.
  static List<Uint8List> _appletAids(Uint8List? component) {
    if (component == null || component.length < 4) return const [];
    final out = <Uint8List>[];
    var q = 4;
    for (var i = 0; i < component[3] && q < component.length; i++) {
      final n = component[q];
      if (q + 1 + n > component.length) break;
      out.add(Hex.sub(component, q + 1, n));
      q += 1 + n + 2;
    }
    return out;
  }
}
