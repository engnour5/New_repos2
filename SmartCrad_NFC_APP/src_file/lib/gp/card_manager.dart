import 'dart:typed_data';

import '../card/card_channel.dart';
import '../core/apdu.dart';
import '../core/errors.dart';
import '../core/hex.dart';
import '../core/log.dart';
import '../core/status_words.dart';
import 'cap_file.dart';
import 'gp_keys.dart';
import 'scp02.dart';

/// Something the card refused. The status word is kept, because 6A 88 ("not found") and 69 85 ("conditions not
/// satisfied") mean very different things when you are deleting a package.
class GpException extends CardException {
  GpException(super.message, {this.sw = -1});

  final int sw;

  @override
  String toString() => sw < 0 ? message : '$message (${h2(sw >> 8)} ${h2(sw & 0xFF)}: ${swMeaning(sw)})';
}

/// The card would not open a channel with this key set: the keys, or the key version, are not the card's.
class GpKeyException extends GpException {
  GpKeyException(super.message, {super.sw});
}

/// What a package or an applet looks like on the card.
class GpEntry {
  GpEntry(this.aid, this.lifeCycle, this.privileges, {this.modules = const [], this.kind = GpKind.application});

  final Uint8List aid;
  final int lifeCycle;
  final int privileges;

  /// For a package: the applets it defines, each of which can be installed as an instance.
  final List<Uint8List> modules;
  final GpKind kind;

  String get aidText => Hex.of(aid);

  /// The card's own name for this AID, when its bytes happen to be readable text.
  String get asText {
    final t = String.fromCharCodes(aid.map((b) => b >= 0x20 && b < 0x7F ? b : 0x2E));
    return RegExp(r'^[ -~]{3,}$').hasMatch(t) ? t : '';
  }

  String get lifeCycleText => switch (kind) {
        GpKind.package => lifeCycle == 0x01 ? 'LOADED' : 'life cycle ${h2(lifeCycle)}',
        GpKind.securityDomain => switch (lifeCycle) {
            0x01 => 'OP_READY',
            0x07 => 'INITIALIZED',
            0x0F => 'SECURED',
            0x7F => 'CARD_LOCKED',
            0xFF => 'TERMINATED',
            _ => 'life cycle ${h2(lifeCycle)}',
          },
        GpKind.application => switch (lifeCycle) {
            0x03 => 'INSTALLED',
            0x07 => 'SELECTABLE',
            0x83 => 'LOCKED',
            _ => lifeCycle >= 0x0F && lifeCycle & 0x07 == 0x07 ? 'PERSONALIZED' : 'life cycle ${h2(lifeCycle)}',
          },
      };

  /// The privilege bits of GlobalPlatform 2.1.1, which is the one-byte form GET STATUS returns here.
  List<String> get privilegeNames => [
        if (privileges & 0x80 != 0) 'Security Domain',
        if (privileges & 0x40 != 0) 'DAP verification',
        if (privileges & 0x20 != 0) 'Delegated management',
        if (privileges & 0x10 != 0) 'Card lock',
        if (privileges & 0x08 != 0) 'Card terminate',
        if (privileges & 0x04 != 0) 'Default selected',
        if (privileges & 0x02 != 0) 'CVM management',
        if (privileges & 0x01 != 0) 'Mandated DAP',
      ];

  bool get isDefaultSelected => privileges & 0x04 != 0;
}

enum GpKind { securityDomain, application, package }

/// Everything GET STATUS found on the card.
class CardContents {
  CardContents(this.isd, this.applications, this.packages);

  final List<GpEntry> isd;
  final List<GpEntry> applications;
  final List<GpEntry> packages;

  int get total => isd.length + applications.length + packages.length;

  GpEntry? package(Uint8List aid) => packages.where((p) => Hex.same(p.aid, aid)).firstOrNull;

  /// Why the card would refuse package [packageAid] installed as [instanceAid], judged from what is on it now; null
  /// when nothing stands in the way. With [deleteFirst], a package with that AID is deleted first, and the applets
  /// installed from it go with it.
  String? loadProblem(Uint8List packageAid,
      {required Uint8List instanceAid, required bool defaultSelected, required bool deleteFirst}) {
    final old = package(packageAid);
    if (old != null && !deleteFirst) {
      return 'The package ${Hex.of(packageAid)} is already on the card, and a card refuses a package it already has. '
          'Tick "Delete the package first", or delete it in the list.';
    }
    // GET STATUS does not say which package an applet came from, so an applet is only sure to outlive the delete when
    // its AID is one that another package defines
    bool stays(GpEntry a) =>
        old == null ||
        (!old.modules.any((m) => Hex.same(m, a.aid)) &&
            packages.any((p) => p != old && p.modules.any((m) => Hex.same(m, a.aid))));
    if (applications.any((a) => Hex.same(a.aid, instanceAid) && stays(a))) {
      return 'An applet with the AID ${Hex.of(instanceAid)} is already on the card. Install under another AID, or '
          'delete that applet first.';
    }
    final owner = defaultSelected ? applications.where((a) => a.isDefaultSelected && stays(a)).firstOrNull : null;
    if (owner != null) {
      return 'The applet ${Hex.of(owner.aid)} already holds "Default selected", and a card allows only one. Delete '
          'that applet first (its package can stay), or untick "Default selected". Turn on Force to delete it for you.';
    }
    return null;
  }

  /// What to delete, in order, to clear the way for installing [packageAid] as [instanceAid] — a Force install: the
  /// applet already using the instance AID, then the applet holding "Default selected" when one is wanted, then the
  /// package with the same AID. Each is tagged with whether the card should also remove what came from it (true).
  ///
  /// When an applet in the way is an instance of a package on the card, the PACKAGE is deleted (which takes the
  /// instance with it): a card refuses to delete a default-selected applet instance on its own (69 85). Only an applet
  /// no package on the card defines is deleted on its own.
  List<(Uint8List aid, bool withRelated)> blockers(Uint8List packageAid,
      {required Uint8List instanceAid, required bool defaultSelected}) {
    final out = <(Uint8List, bool)>[];
    final seen = <String>{};
    void add(Uint8List aid, bool withRelated) {
      if (seen.add(Hex.of(aid))) out.add((aid, withRelated));
    }

    // delete the package that defines the applet, or the applet on its own when no package on the card does
    void clear(Uint8List appletAid) {
      final owner = packages.where((p) => p.modules.any((m) => Hex.same(m, appletAid))).firstOrNull;
      owner != null ? add(owner.aid, true) : add(appletAid, false);
    }

    final taken = applications.where((a) => Hex.same(a.aid, instanceAid)).firstOrNull;
    if (taken != null) clear(taken.aid);
    if (defaultSelected) {
      final owner = applications.where((a) => a.isDefaultSelected).firstOrNull;
      if (owner != null) clear(owner.aid);
    }
    final pkg = package(packageAid);
    if (pkg != null) add(pkg.aid, true);
    return out;
  }
}

/// The card manager side of the card: open a secure channel with the card's keys, then read what is on it, delete a
/// package, or load and install a CAP file.
///
/// This talks straight to the reader, not through the phone rules: no phone ever sends these commands.
class CardManager {
  CardManager(this.channel, this.log);

  /// The Issuer Security Domain of the test card. The applet under test is the default applet, so the ISD has to be
  /// selected by its AID: an empty SELECT would reach the applet instead.
  static final defaultIsdAid = Hex.parse('A000000151000000');

  /// The largest LOAD block. A command and its 8-byte C-MAC must fit in 255 bytes.
  static const maxLoadBlock = 240;

  final CardChannel channel;
  final Logger log;

  Uint8List isdAid = defaultIsdAid;
  Scp02Session? _session;

  /// What the card said about itself at INITIALIZE UPDATE.
  InitializeUpdateResponse? initializeUpdate;

  bool get open => _session?.open ?? false;

  void close() {
    _session = null;
    initializeUpdate = null;
  }

  // ------------------------------------------------------------------ plain commands

  Future<ResponseApdu> _send(Uint8List apdu, String label) async {
    final watch = Stopwatch()..start();
    final response = ResponseApdu.fromRaw(await channel.transmit(apdu));
    log.exchange(label, apdu, response, watch.elapsedMicroseconds / 1000);
    return response;
  }

  /// Sends a command through the secure channel, adding its C-MAC.
  Future<ResponseApdu> _secure(int cla, int ins, int p1, int p2, Uint8List data, String label, {int? le}) async {
    final s = _session;
    if (s == null || !s.open) throw GpException('The secure channel is not open. Authenticate first.');
    return _send(s.wrap(cla, ins, p1, p2, data, le: le), label);
  }

  ResponseApdu _expect(ResponseApdu r, String what) {
    if (r.sw != 0x9000) throw GpException('$what failed', sw: r.sw);
    return r;
  }

  /// SELECT by AID, outside any secure channel. This is what a reader or a phone app does to pick an applet.
  Future<ResponseApdu> selectAid(Uint8List aid) async {
    final apdu = Hex.concat([
      [0x00, 0xA4, 0x04, 0x00, aid.length],
      aid,
      [0x00],
    ]);
    return _send(apdu, 'SELECT ${Hex.of(aid)}');
  }

  // ------------------------------------------------------------------ the secure channel

  /// INITIALIZE UPDATE and EXTERNAL AUTHENTICATE, the two steps that prove host and card share the key set.
  ///
  /// A wrong key makes the card refuse the second step, and cards count those refusals, so this stops at the first
  /// failure rather than trying anything else.
  Future<void> authenticate(GpKeys keys, {Uint8List? hostChallenge}) async {
    if (!keys.usable) throw GpException('The key set is not three 16-byte keys.');
    close();
    log.section('Card manager: opening a secure channel (SCP02)');

    _expect(await selectAid(isdAid), 'SELECT of the card manager ${Hex.of(isdAid)}');

    final challenge = hostChallenge ?? Scp02Session.newHostChallenge();
    final initResponse = await _send(
        Hex.concat([
          [0x80, 0x50, keys.keyVersion, 0x00, 0x08],
          challenge,
          [0x00],
        ]),
        'INITIALIZE UPDATE');
    if (initResponse.sw == 0x6A88 && keys.keyVersion != 0) {
      throw GpKeyException('The card has no key set with key version ${keys.keyVersion}. Choose "any" to let the card '
          'pick, or the key version the card uses. Nothing else was sent.', sw: initResponse.sw);
    }
    final init = _expect(initResponse, 'INITIALIZE UPDATE');
    if (init.data.length != InitializeUpdateResponse.length) {
      throw GpException('INITIALIZE UPDATE answered ${init.data.length} bytes; SCP02 sends ${InitializeUpdateResponse.length}.');
    }
    final info = InitializeUpdateResponse(init.data);
    initializeUpdate = info;
    if (info.scpId != 0x02) {
      throw GpException('The card uses secure channel protocol ${h2(info.scpId)}; this tool speaks SCP02 only.');
    }
    log.info('Card manager: key version ${info.keyVersion}, SCP${h2(info.scpId)}, sequence counter ${info.sequenceCounter}.');

    final session = Scp02Session.fromStaticKeys(keys.enc, keys.mac, keys.dek, info.sequenceCounter);
    final expected = cardCryptogram(session.sEnc, challenge, info.cardChallenge);
    if (!Hex.same(expected, info.cardCryptogram)) {
      throw GpKeyException('The card did not prove it has the same keys (its cryptogram does not match). '
          'The key set, or the key version, is wrong for this card. Nothing else was sent.');
    }
    log.info('The card proved it has the same key set.');

    // from here on every command carries a C-MAC, EXTERNAL AUTHENTICATE first
    _session = session;
    session.open = true;
    final host = hostCryptogram(session.sEnc, info.cardChallenge, challenge);
    try {
      _expect(await _secure(0x80, 0x82, 0x01, 0x00, host, 'EXTERNAL AUTHENTICATE'), 'EXTERNAL AUTHENTICATE');
    } catch (e) {
      close();
      rethrow;
    }
    log.info('Secure channel open (C-MAC on every command).');
  }

  // ------------------------------------------------------------------ reading what is on the card

  /// GET STATUS for one kind of thing, following the card's "there is more" answer (61 10 / 63 10).
  Future<List<GpEntry>> _getStatus(int p1, GpKind kind, String what) async {
    final entries = <GpEntry>[];
    var p2 = 0x00; // 0x00 = first or all occurrences, 0x01 = next
    while (true) {
      final r = await _secure(0x80, 0xF2, p1, p2, Hex.parse('4F 00'), 'GET STATUS $what', le: 0x00);
      if (r.sw == 0x6A88) break; // nothing of this kind on the card
      if (r.sw != 0x9000 && r.sw != 0x6310) _expect(r, 'GET STATUS $what');
      entries.addAll(_parseStatus(r.data, kind));
      if (r.sw != 0x6310) break;
      p2 = 0x01;
    }
    return entries;
  }

  static List<GpEntry> _parseStatus(Uint8List data, GpKind kind) {
    final out = <GpEntry>[];
    var p = 0;
    while (p < data.length) {
      final length = data[p];
      if (length == 0 || p + 1 + length + 2 > data.length) break;
      final aid = Hex.sub(data, p + 1, length);
      final lifeCycle = data[p + 1 + length];
      final privileges = data[p + 2 + length];
      p += 3 + length;
      final modules = <Uint8List>[];
      if (kind == GpKind.package) {
        // the "load files and modules" answer counts the applets of the package after the privileges byte
        if (p >= data.length) break;
        final count = data[p++];
        for (var i = 0; i < count && p < data.length; i++) {
          final n = data[p];
          if (p + 1 + n > data.length) break;
          modules.add(Hex.sub(data, p + 1, n));
          p += 1 + n;
        }
      }
      out.add(GpEntry(aid, lifeCycle, privileges, modules: modules, kind: kind));
    }
    return out;
  }

  /// Reads the card manager, the applets and the packages with their applets.
  Future<CardContents> readCard() async {
    log.section('Card manager: reading what is on the card');
    final isd = await _getStatus(0x80, GpKind.securityDomain, 'card manager');
    final applications = await _getStatus(0x40, GpKind.application, 'applets');
    final packages = await _getStatus(0x10, GpKind.package, 'packages and their applets');
    log.info('On the card: ${packages.length} package${packages.length == 1 ? '' : 's'}, '
        '${applications.length} applet${applications.length == 1 ? '' : 's'}.');
    return CardContents(isd, applications, packages);
  }

  // ------------------------------------------------------------------ changing what is on the card

  /// DELETE. With [withRelated] the card also removes the applet instances that came from this package, which is what
  /// deleting a package needs; without it, the card refuses while an instance is still there.
  Future<void> delete(Uint8List aid, {bool withRelated = true}) async {
    log.section('Card manager: deleting ${Hex.of(aid)}${withRelated ? ' and what came from it' : ''}');
    final data = Hex.concat([
      [0x4F, aid.length],
      aid,
    ]);
    final r = await _secure(0x80, 0xE4, 0x00, withRelated ? 0x80 : 0x00, data, 'DELETE ${Hex.of(aid)}', le: 0x00);
    if (r.sw == 0x6A88) throw GpException('There is nothing with the AID ${Hex.of(aid)} on the card.', sw: r.sw);
    _expect(r, 'DELETE ${Hex.of(aid)}');
    log.info('Deleted ${Hex.of(aid)}.');
  }

  /// INSTALL [for load], then the LOAD blocks, then INSTALL [for install and make selectable].
  ///
  /// [onProgress] is called with the block number and the total, so a screen can show the bar moving.
  Future<void> loadCap(
    CapFile cap, {
    required Uint8List instanceAid,
    required Uint8List moduleAid,
    int privileges = 0x00,
    int blockSize = maxLoadBlock,
    void Function(int done, int total)? onProgress,
  }) async {
    final blocks = cap.loadBlocks(blockSize: blockSize.clamp(16, maxLoadBlock));
    log.section('Card manager: loading ${cap.name} (${cap.componentBytes} bytes in ${blocks.length} blocks)');

    // 1. tell the card a package is coming
    final forLoad = Hex.concat([
      [cap.packageAid.length],
      cap.packageAid,
      [0x00, 0x00, 0x00, 0x00], // no security domain AID, no hash, no parameters, no token
    ]);
    _expect(await _secure(0x80, 0xE6, 0x02, 0x00, forLoad, 'INSTALL [for load]', le: 0x00), 'INSTALL [for load]');

    // 2. the package itself
    for (var i = 0; i < blocks.length; i++) {
      final last = i == blocks.length - 1;
      _expect(await _secure(0x80, 0xE8, last ? 0x80 : 0x00, i, blocks[i], 'LOAD ${i + 1}/${blocks.length}', le: 0x00),
          'LOAD block ${i + 1} of ${blocks.length}');
      onProgress?.call(i + 1, blocks.length);
    }
    log.info('The package is on the card. Installing the applet.');

    // 3. make an applet instance of it, selectable
    final forInstall = Hex.concat([
      [cap.packageAid.length],
      cap.packageAid,
      [moduleAid.length],
      moduleAid,
      [instanceAid.length],
      instanceAid,
      [0x01, privileges],
      [0x02, 0xC9, 0x00], // empty application-specific install parameters
      [0x00], // no token
    ]);
    final installed = await _secure(0x80, 0xE6, 0x0C, 0x00, forInstall, 'INSTALL [for install and make selectable]', le: 0x00);
    if (installed.sw != 0x9000) {
      // the package is on the card but has no applet instance, so say what state the card is in
      final leftOver = 'The package ${Hex.of(cap.packageAid)} is now on the card with no applet installed from it: '
          'delete it, or load it again.';
      if (installed.sw == 0x6985 && privileges & 0x04 != 0) {
        throw GpException(
            'The card would not make this applet the default selected one. A card allows only one applet with that '
            'privilege, and another applet already has it: delete that one first, or install without "Default '
            'selected". $leftOver',
            sw: installed.sw);
      }
      throw GpException('INSTALL [for install and make selectable] failed. $leftOver', sw: installed.sw);
    }
    log.info('Installed ${Hex.of(instanceAid)}${privileges & 0x04 != 0 ? ' as the default applet' : ''}.');
  }
}
