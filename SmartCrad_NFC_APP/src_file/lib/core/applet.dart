import 'dart:typed_data';

import 'hex.dart';

/// The applet the tool talks to.
///
/// It is a setting, not a constant. Burning an applet with another AID used to leave every other screen selecting the
/// old one, and a SELECT that fails leaves the card with nothing selected, so the next command failed too. Everything
/// that selects the applet now reads this from the AID box instead.
abstract final class AppletAid {
  /// What the test card has carried since 1 Oct 2026: "EMG0000000".
  static const defaultHex = '45 4D 47 30 30 30 30 30 30 30';

  static Uint8List get byDefault => Hex.parse(defaultHex);

  /// SELECT by AID, with the length byte taken from the AID rather than fixed at 0A, so an AID of any length works.
  static String select(Uint8List aid) => '00 A4 04 00 ${h2(aid.length)} ${Hex.of(aid)}';

  /// The first few bytes, for naming a check without printing the whole AID.
  static String short(Uint8List aid) => aid.length <= 4 ? Hex.of(aid) : '${Hex.of(aid, 0, 4)}...';
}
