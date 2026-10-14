import 'dart:typed_data';

import 'errors.dart';
import 'hex.dart';

/// A command APDU split into its ISO 7816-4 fields, the way Core NFC's NFCISO7816APDU holds it.
class CommandApdu {
  CommandApdu(this.cla, this.ins, this.p1, this.p2,
      {Uint8List? data, this.ne = -1, this.apduCase = 1, this.extended = false})
      : data = data ?? Uint8List(0);

  final int cla, ins, p1, p2;
  final Uint8List data;

  /// Expected response length: -1 = no Le field, otherwise 1..65536 (256 = short Le 00).
  final int ne;
  final int apduCase;
  final bool extended;

  /// Splits raw bytes into fields. Returns the reason when iOS could not build an NFCISO7816APDU from them.
  static (CommandApdu?, String?) parse(Uint8List raw) {
    if (raw.length < 4) return (null, 'An APDU needs at least 4 bytes (CLA INS P1 P2).');
    final n = raw.length;
    CommandApdu make(int apduCase, {Uint8List? data, int ne = -1, bool ext = false}) =>
        CommandApdu(raw[0], raw[1], raw[2], raw[3], data: data, ne: ne, apduCase: apduCase, extended: ext);
    if (n == 4) return (make(1), null);
    if (n == 5) return (make(2, ne: raw[4] == 0 ? 256 : raw[4]), null);
    if (raw[4] != 0) {
      final lc = raw[4];
      if (n == 5 + lc) return (make(3, data: Hex.sub(raw, 5, lc)), null);
      if (n == 6 + lc) return (make(4, data: Hex.sub(raw, 5, lc), ne: raw[n - 1] == 0 ? 256 : raw[n - 1]), null);
      return (null, 'Lc is ${h2(lc)} ($lc bytes), but ${n - 5} bytes follow it.');
    }
    // Byte 5 is 00 and more bytes follow: extended length.
    if (n < 7) return (null, 'Byte 5 is 00 (extended length), but the APDU is too short for that.');
    if (n == 7) {
      final le = (raw[5] << 8) | raw[6];
      return (make(2, ne: le == 0 ? 65536 : le, ext: true), null);
    }
    final elc = (raw[5] << 8) | raw[6];
    if (elc == 0) return (null, 'Extended Lc is 0000.');
    if (n == 7 + elc) return (make(3, data: Hex.sub(raw, 7, elc), ext: true), null);
    if (n == 9 + elc) {
      final le = (raw[n - 2] << 8) | raw[n - 1];
      return (make(4, data: Hex.sub(raw, 7, elc), ne: le == 0 ? 65536 : le, ext: true), null);
    }
    return (null, 'Extended Lc is ${h4(elc)} ($elc bytes), but the APDU length does not match.');
  }

  /// The bytes Core NFC sends for these fields: the short form when it fits, the extended form otherwise.
  Uint8List encode() {
    final ext = data.length > 255 || ne > 256;
    final b = BytesBuilder();
    b.add([cla, ins, p1, p2]);
    if (data.isNotEmpty) {
      if (ext) {
        b.add([0, data.length >> 8, data.length & 0xFF]);
      } else {
        b.addByte(data.length);
      }
      b.add(data);
    }
    if (ne > 0) {
      if (ext) {
        if (data.isEmpty) b.addByte(0);
        final v = ne == 65536 ? 0 : ne;
        b.add([v >> 8, v & 0xFF]);
      } else {
        b.addByte(ne == 256 ? 0 : ne);
      }
    }
    return b.toBytes();
  }
}

/// A response APDU: the data and SW1 SW2.
class ResponseApdu {
  ResponseApdu(this.data, this.sw1, this.sw2);

  final Uint8List data;
  final int sw1, sw2;

  int get sw => (sw1 << 8) | sw2;
  String get swText => '${h2(sw1)} ${h2(sw2)}';
  String get swCompact => '${h2(sw1)}${h2(sw2)}';

  static ResponseApdu fromRaw(Uint8List raw) {
    if (raw.length < 2) throw CardException('The answer has no status word.');
    return ResponseApdu(Hex.sub(raw, 0, raw.length - 2), raw[raw.length - 2], raw[raw.length - 1]);
  }
}

/// The name of an instruction this card knows, or an empty string.
String insName(int cla, int ins, int p1) {
  switch (ins) {
    case 0xA4:
      return p1 == 0x04 ? 'SELECT by AID' : 'SELECT by file ID';
    case 0xB0:
      return 'READ BINARY';
    case 0xD6:
      return 'UPDATE BINARY (writes to the card)';
    case 0x08:
      return cla == 0x80 ? 'GET UID (card ID)' : '';
    case 0xC0:
      return 'GET RESPONSE';
    case 0xCA:
      return 'GET DATA';
  }
  return '';
}

/// "CLA 00 · INS B0 READ BINARY · P1 7F · P2 00 · Le 00 (256 bytes)", or why the bytes are not a valid APDU.
String describeCommand(Uint8List raw) {
  if (raw.isEmpty) return '';
  final (c, error) = CommandApdu.parse(raw);
  if (c == null) return 'Not a valid ISO 7816 APDU: $error';
  final name = insName(c.cla, c.ins, c.p1);
  final parts = <String>[
    'CLA ${h2(c.cla)}',
    'INS ${h2(c.ins)}${name.isEmpty ? '' : ' $name'}',
    'P1 ${h2(c.p1)}',
    'P2 ${h2(c.p2)}',
  ];
  if (c.ins == 0xB0 || c.ins == 0xD6) parts.add('offset ${h4(((c.p1 & 0x7F) << 8) | c.p2)}');
  if (c.data.isNotEmpty) parts.add('Lc ${c.data.length} byte${c.data.length == 1 ? '' : 's'}');
  if (c.ne >= 0) parts.add('Le ${c.ne == 256 ? '00 (256 bytes)' : (c.ne == 65536 ? '0000 (65536 bytes)' : '${c.ne} byte${c.ne == 1 ? '' : 's'}')}');
  return parts.join('  ·  ');
}
