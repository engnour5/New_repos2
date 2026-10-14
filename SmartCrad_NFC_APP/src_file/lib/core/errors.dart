/// A problem talking to the card or the reader.
class CardException implements Exception {
  CardException(this.message, [this.code = 0]);

  final String message;
  final int code;

  @override
  String toString() => message;
}
