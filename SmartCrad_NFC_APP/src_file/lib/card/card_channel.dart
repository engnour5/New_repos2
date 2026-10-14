import 'dart:typed_data';

/// A card the tool talks to: a PC/SC reader slot, or the built-in simulator.
abstract class CardChannel {
  String get name;
  bool get isSimulated;
  Uint8List? get atr;

  /// Connects and powers the card, if that is not done yet.
  Future<void> connect();

  /// Field off and on, as when the card leaves the phone and comes back.
  Future<void> fieldReset();

  /// Sends raw bytes. Returns the raw answer, SW1 SW2 included.
  Future<Uint8List> transmit(Uint8List apdu);

  /// The contactless UID, or null when the reader cannot give it.
  Future<Uint8List?> getUid();

  /// Lets other programs use the reader again.
  Future<void> disconnect();

  Future<void> dispose();
}
