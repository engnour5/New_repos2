import 'dart:typed_data';

import 'hex.dart';

/// What the ATR says about the card. A PC/SC contactless reader builds the ATR as 3B 8n 80 01 + historical bytes.
class AtrInfo {
  bool isoDep = false;
  bool storage = false;
  bool contactlessFormat = false;
  Uint8List? historical;
  String description = '';

  static AtrInfo parse(Uint8List? atr) {
    final info = AtrInfo();
    if (atr == null || atr.length < 2) {
      info.description = 'no ATR';
      return info;
    }
    info.historical = historicalBytes(atr);
    info.contactlessFormat = atr.length >= 4 && atr[0] == 0x3B && (atr[1] & 0xF0) == 0x80 && atr[2] == 0x80 && atr[3] == 0x01;
    final h = info.historical;
    if (info.contactlessFormat &&
        h != null &&
        h.length >= 8 &&
        h[0] == 0x80 &&
        h[1] == 0x4F &&
        h[2] == 0x0C &&
        Hex.same(h.sublist(3, 8), const [0xA0, 0x00, 0x00, 0x03, 0x06])) {
      info.storage = true;
      info.description = 'contactless memory card (MIFARE Classic, Ultralight or similar). It has no APDU interface, '
          'so a phone app cannot send APDUs to it.';
    } else if (info.contactlessFormat) {
      info.isoDep = true;
      info.description = 'contactless smart card, ISO 14443-4 (ISO-DEP). A phone can send APDUs to this kind of card.';
    } else {
      info.description = 'contact-card ATR (ISO 7816-3). A phone cannot use the contact interface; '
          'check the card on a contactless reader.';
    }
    return info;
  }

  static Uint8List? historicalBytes(Uint8List atr) {
    if (atr.length < 2) return null;
    final k = atr[1] & 0x0F;
    var y = atr[1] >> 4;
    var pos = 2;
    while (true) {
      if ((y & 1) != 0) pos++; // TA
      if ((y & 2) != 0) pos++; // TB
      if ((y & 4) != 0) pos++; // TC
      if ((y & 8) == 0) break; // no TD
      if (pos >= atr.length) return null;
      y = atr[pos] >> 4;
      pos++;
    }
    if (pos + k > atr.length) return null;
    return Hex.sub(atr, pos, k);
  }

  static bool looksContactless(String? readerName) {
    if (readerName == null) return false;
    final n = readerName.toLowerCase();
    return n.contains('contactless') || n.contains('picc') || n.contains(' cl ');
  }
}
