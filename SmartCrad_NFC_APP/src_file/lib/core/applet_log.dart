import 'dart:typed_data';

import 'hex.dart';

/// One 16-byte record from the applet's own command logger, read back with `80 F3`:
///   [0..4] CLA INS P1 P2 P3  ·  [5..13] first 9 bytes of the command data (the full AID of a SELECT)  ·  [14..15] SW
///
/// The applet writes one of these for every command it receives while logging is on (`80 F0`), into its own buffer -
/// never the 32 KB data file - so it does not change what a normal read returns.
class AppletLogRecord {
  AppletLogRecord(this.bytes); // exactly 16 bytes

  final Uint8List bytes;

  static const size = 16;

  int get cla => bytes[0] & 0xff;
  int get ins => bytes[1] & 0xff;
  int get p1 => bytes[2] & 0xff;
  int get p2 => bytes[3] & 0xff;
  int get p3 => bytes[4] & 0xff;
  Uint8List get data => Hex.sub(bytes, 5, 9); // first 9 bytes of the command data (the full AID on a SELECT, data on UPDATE)
  int get sw => ((bytes[14] & 0xff) << 8) | (bytes[15] & 0xff);
  int get offset => (p1 << 8) | p2;
  bool get ok => sw == 0x9000;

  String get headerHex => '${h2(cla)} ${h2(ins)} ${h2(p1)} ${h2(p2)} ${h2(p3)}';
  String get swText => '${h2(bytes[14] & 0xff)} ${h2(bytes[15] & 0xff)}';

  /// What the command was, in words.
  String get command {
    switch (ins) {
      case 0xA4:
        if (p1 == 0x04) return 'SELECT by AID  ${Hex.of(data)}…';
        final fid = (data[0] << 8) | data[1];
        if (fid == 0x3040) return 'SELECT EF 3040';
        if (fid == 0x3F00) return 'SELECT MF 3F00';
        if (p3 == 0) return 'SELECT (no data)';
        return 'SELECT file ${h2(data[0])}${h2(data[1])}';
      case 0xB0:
        return 'READ  @${h4(offset)}  Le ${h2(p3)}';
      case 0xD6:
        return 'UPDATE @${h4(offset)}  Lc ${h2(p3)}';
      case 0x08:
        return 'GET UID';
      case 0xF0:
        return 'LOG reset';
      case 0xF1:
        return 'LOG freeze';
      case 0xF2:
        return 'LOG status';
      case 0xF3:
        return 'LOG read';
      default:
        return 'INS ${h2(ins)}';
    }
  }

  /// What the status word means, short.
  String get swMeaning {
    final s = sw;
    if (s == 0x9000) return 'OK';
    if ((s & 0xff00) == 0x6C00) return 'only ${s & 0xff} bytes left — re-read with Le=${h2(s & 0xff)} (6Cxx; Android does NOT auto-retry)';
    if ((s & 0xff00) == 0x6100) return 'more data available (61xx)';
    switch (s) {
      case 0x6986:
        return 'no file selected — SELECT 3040 first';
      case 0x6982:
        return 'security status not satisfied';
      case 0x6A82:
        return 'file / application not found';
      case 0x6A86:
        return 'incorrect P1-P2';
      case 0x6700:
        return 'wrong length';
      case 0x6B00:
        return 'wrong P1-P2 (offset past end)';
      case 0x6D00:
        return 'INS not supported';
      case 0x6E00:
        return 'CLA not supported';
      case 0x6F00:
        return 'no precise diagnosis';
      case 0x6999:
        return 'applet selection failed';
      default:
        return '';
    }
  }
}
