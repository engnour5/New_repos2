import 'dart:typed_data';

import 'apdu.dart';
import 'hex.dart';

/// One entry of the app's Info.plist list com.apple.developer.nfc.readersession.iso7816.select-identifiers.
class AidEntry {
  AidEntry(this.text);

  final String text;
  Uint8List? aid;
  String? problem; // why iOS cannot use this entry (null = usable)
  String? warning; // usable, but worth confirming on a real iPhone
  String? kind; // ISO 7816-5 category of the AID

  bool get usable => problem == null;
}

/// Core NFC rules for ISO 7816 cards, from Apple's NFCISO7816Tag.h and NFCTagReaderSession.h:
/// the card is found by a SELECT of the listed AIDs, in order, and the app may only SELECT (P1 = 04) AIDs of the list.
class IosRules {
  final List<AidEntry> entries = [];

  /// Apple blocks payment AIDs but does not publish the list. These are well-known payment RIDs and directories.
  static const List<(String, String)> paymentAids = [
    ('A000000003', 'Visa, also the old card manager A000000003000000'),
    ('A000000004', 'Mastercard'),
    ('A000000025', 'American Express'),
    ('A000000065', 'JCB'),
    ('A000000152', 'Discover / Diners'),
    ('A000000324', 'Discover'),
    ('A000000333', 'UnionPay'),
    ('A000000277', 'Interac'),
    ('A000000042', 'CB'),
    ('A000000524', 'RuPay'),
    ('A000000658', 'Mir'),
    ('325041592E5359532E4444463031', 'PPSE 2PAY.SYS.DDF01'),
    ('315041592E5359532E4444463031', 'PSE 1PAY.SYS.DDF01'),
  ];

  /// Entries are separated by commas, semicolons or new lines; spaces inside an entry are allowed.
  static IosRules parse(String text) {
    final rules = IosRules();
    for (final token in text.split(RegExp(r'[,;\r\n]+'))) {
      final t = token.trim();
      if (t.isEmpty) continue;
      final e = AidEntry(t.replaceAll(' ', '').toUpperCase());
      rules.entries.add(e);
      Uint8List aid;
      try {
        aid = Hex.parse(t);
      } on FormatException catch (ex) {
        e.problem = 'not valid hex: ${ex.message}';
        continue;
      }
      if (aid.isEmpty) {
        e.problem = 'empty entry';
        continue;
      }
      e.aid = aid;
      e.kind = category(aid);
      final payment = paymentName(aid);
      if (payment != null) {
        e.problem = 'payment AID ($payment). iOS blocks payment AIDs, so it never selects this one.';
      } else if (aid.length < 5 || aid.length > 16) {
        e.warning = 'ISO 7816 AIDs are 5 to 16 bytes long; this one has ${aid.length}. iOS may refuse it.';
      } else if (!_standardCategory(aid)) {
        e.warning = 'starts with ${(aid[0] >> 4).toRadixString(16).toUpperCase()}: not a registered (A, D) or proprietary (F) AID. '
            'Apple has no written rule against it, but one developer saw iOS refuse such an AID. Confirm on a real iPhone.';
      }
    }
    return rules;
  }

  static String category(Uint8List aid) {
    final digit = aid[0] >> 4;
    final rid = Hex.compact(aid.sublist(0, aid.length < 5 ? aid.length : 5));
    switch (digit) {
      case 0xA:
        return 'internationally registered AID (RID $rid)';
      case 0xD:
        return 'nationally registered AID (RID $rid)';
      case 0xF:
        return 'proprietary AID (not registered)';
      default:
        return 'ISO 7816-5 category ${digit.toRadixString(16).toUpperCase()}';
    }
  }

  static bool _standardCategory(Uint8List aid) {
    final digit = aid[0] >> 4;
    return digit == 0xA || digit == 0xD || digit == 0xF;
  }

  static String? paymentName(Uint8List aid) {
    final hex = Hex.compact(aid);
    for (final (prefix, name) in paymentAids) {
      if (hex.startsWith(prefix)) return name;
    }
    return null;
  }

  /// Apple: "a SELECT command with a P1 value of 0x04 (selection by DF name) will be checked against the values listed
  /// in select-identifiers ... Selecting an application outside of the permissible list will result in a
  /// NFCReaderErrorSecurityViolation error." Returns null when the command may go to the card.
  String? checkSelect(CommandApdu c) {
    if (c.ins != 0xA4 || c.p1 != 0x04) return null;
    final payment = paymentName(c.data);
    if (payment != null) {
      return 'blocked by iOS: SELECT of a payment AID ($payment). Core NFC refuses it ("Missing required entitlement"), '
          'so the card never receives it.';
    }
    for (final e in entries) {
      if (e.usable && Hex.same(e.aid, c.data)) return null;
    }
    final what = c.data.isEmpty ? 'an empty AID' : Hex.compact(c.data);
    return "blocked by iOS: SELECT by AID (P1 = 04) of $what, which is not in the app's AID list. "
        'Core NFC returns NFCReaderErrorSecurityViolation, so the card never receives it.';
  }
}
