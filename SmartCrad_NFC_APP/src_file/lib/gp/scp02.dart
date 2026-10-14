import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../core/hex.dart';

/// GlobalPlatform Secure Channel Protocol 02, as the test card reports it: SCP02 i=55
/// (3 secure channel keys, C-MAC over the modified APDU, explicit initiation, ICV of zero at the start,
/// ICV encrypted between commands, no R-MAC).
///
/// Only the card's own keys open this channel. They never go on the wire: the card and the host each work out the
/// same session keys from the sequence counter, and prove it with an 8-byte cryptogram.

// ------------------------------------------------------------------ DES and 3DES

/// 3DES (DES-EDE2, a 16-byte key) in CBC mode. [data] must be a whole number of 8-byte blocks.
Uint8List des3CbcEncrypt(Uint8List key, Uint8List iv, Uint8List data) =>
    _run(CBCBlockCipher(DESedeEngine())..init(true, ParametersWithIV(KeyParameter(key), iv)), data);

/// Single DES in CBC mode, used for all but the last block of an SCP02 C-MAC.
Uint8List desCbcEncrypt(Uint8List key8, Uint8List iv, Uint8List data) => des3CbcEncrypt(_single(key8), iv, data);

/// One block of single DES, with no chaining: used to encrypt the ICV between commands.
Uint8List desEcbBlock(Uint8List key8, Uint8List block) =>
    _run(DESedeEngine()..init(true, KeyParameter(_single(key8))), block);

/// Single DES built from the 3DES engine: DES-EDE with the same key twice is encrypt, decrypt, encrypt with one key,
/// and the middle step undoes the first, so it comes out as plain DES. One engine then covers both.
Uint8List _single(Uint8List key8) => Hex.concat([key8, key8]);

Uint8List _run(BlockCipher c, Uint8List data) {
  final out = Uint8List(data.length);
  for (var o = 0; o < data.length; o += c.blockSize) {
    c.processBlock(data, o, out, o);
  }
  return out;
}

/// ISO 9797-1 padding method 2: a 0x80 byte, then zeros up to a whole 8-byte block.
Uint8List pad80(Uint8List data) {
  final out = Uint8List(data.length + 8 - (data.length % 8))..setAll(0, data);
  out[data.length] = 0x80;
  return out;
}

Uint8List _last8(Uint8List b) => Uint8List.sublistView(b, b.length - 8);

// ------------------------------------------------------------------ SCP02 key derivation and cryptograms

/// The two-byte constants that turn a static key into a session key.
class _Derive {
  static const cMac = 0x0101;
  static const rMac = 0x0102;
  static const dek = 0x0181;
  static const sEnc = 0x0182;
}

/// A session key: 3DES-CBC (IV of zeros) of "constant | sequence counter | 12 zero bytes" with the static key.
Uint8List deriveSessionKey(Uint8List staticKey, int constant, int sequenceCounter) {
  final data = Uint8List(16)
    ..[0] = constant >> 8
    ..[1] = constant & 0xFF
    ..[2] = sequenceCounter >> 8
    ..[3] = sequenceCounter & 0xFF;
  return des3CbcEncrypt(staticKey, Uint8List(8), data);
}

/// The 8-byte proof each side gives the other: 3DES-CBC over the padded challenges, keeping the last block.
Uint8List _cryptogram(Uint8List sEnc, Uint8List data) => _last8(des3CbcEncrypt(sEnc, Uint8List(8), pad80(data)));

/// What the card proves with: host challenge, then its sequence counter and challenge.
Uint8List cardCryptogram(Uint8List sEnc, Uint8List hostChallenge, Uint8List cardChallengeWithCounter) =>
    _cryptogram(sEnc, Hex.concat([hostChallenge, cardChallengeWithCounter]));

/// What the host proves with: the card's counter and challenge, then the host challenge.
Uint8List hostCryptogram(Uint8List sEnc, Uint8List cardChallengeWithCounter, Uint8List hostChallenge) =>
    _cryptogram(sEnc, Hex.concat([cardChallengeWithCounter, hostChallenge]));

/// The SCP02 C-MAC: single DES for every block but the last, then one full 3DES, starting from [icv].
Uint8List computeCMac(Uint8List macKey, Uint8List icv, Uint8List data) {
  final padded = pad80(data);
  var chain = icv;
  if (padded.length > 8) {
    final head = Uint8List.sublistView(padded, 0, padded.length - 8);
    chain = _last8(desCbcEncrypt(Uint8List.sublistView(macKey, 0, 8), icv, head));
  }
  return _last8(des3CbcEncrypt(macKey, chain, _last8(padded)));
}

// ------------------------------------------------------------------ the open channel

/// What the card answers to INITIALIZE UPDATE.
class InitializeUpdateResponse {
  InitializeUpdateResponse(this.raw)
      : keyDiversification = Hex.sub(raw, 0, 10),
        keyVersion = raw[10],
        scpId = raw[11],
        sequenceCounter = (raw[12] << 8) | raw[13],
        cardChallenge = Hex.sub(raw, 12, 8), // the 2-byte counter and the card's 6 random bytes, together
        cardCryptogram = Hex.sub(raw, 20, 8);

  final Uint8List raw;
  final Uint8List keyDiversification;
  final int keyVersion;
  final int scpId;
  final int sequenceCounter;

  /// The 8 bytes the cryptograms are built from: the 2-byte counter and the card's 6 random bytes.
  final Uint8List cardChallenge;
  final Uint8List cardCryptogram;

  static const length = 28;
}

/// An open SCP02 session: it holds the session keys and the running ICV, and wraps each command with its C-MAC.
class Scp02Session {
  Scp02Session({required this.sEnc, required this.sMac, required this.sDek, required this.sequenceCounter});

  /// Works out the session keys from the static keys and the counter the card reported.
  factory Scp02Session.fromStaticKeys(Uint8List enc, Uint8List mac, Uint8List dek, int sequenceCounter) =>
      Scp02Session(
        sEnc: deriveSessionKey(enc, _Derive.sEnc, sequenceCounter),
        sMac: deriveSessionKey(mac, _Derive.cMac, sequenceCounter),
        sDek: deriveSessionKey(dek, _Derive.dek, sequenceCounter),
        sequenceCounter: sequenceCounter,
      );

  final Uint8List sEnc;
  final Uint8List sMac;
  final Uint8List sDek;
  final int sequenceCounter;

  Uint8List _icv = Uint8List(8); // zero before the first command of the session
  bool open = false;

  /// The R-MAC session key is not derived: this profile (i=55) has no R-MAC.
  Uint8List get rMacKeyUnused => deriveSessionKey(sMac, _Derive.rMac, sequenceCounter);

  /// Adds the C-MAC to one command, the way SCP02 "C-MAC on the modified APDU" wants it: CLA gains 0x04 and Lc
  /// grows by the 8 MAC bytes, and those same bytes are what the MAC is computed over.
  Uint8List wrap(int cla, int ins, int p1, int p2, Uint8List data, {int? le}) {
    if (data.length + 8 > 255) {
      throw ArgumentError('A command with its C-MAC must fit in 255 bytes; this one is ${data.length + 8}.');
    }
    final header = Uint8List.fromList([cla | 0x04, ins, p1, p2, data.length + 8]);
    final mac = computeCMac(sMac, _icv, Hex.concat([header, data]));
    // the ICV for the next command is this MAC, encrypted with the first half of the MAC session key
    _icv = desEcbBlock(Uint8List.sublistView(sMac, 0, 8), mac);
    return Hex.concat([header, data, mac, if (le != null) [le]]);
  }

  /// A fresh 8-byte host challenge.
  static Uint8List newHostChallenge([Random? random]) {
    final r = random ?? Random.secure();
    return Uint8List.fromList(List<int>.generate(8, (_) => r.nextInt(256)));
  }
}
