import 'dart:typed_data';

import 'hex.dart';

/// One named field of the identity block at the start of a meter card.
class CardField {
  const CardField(this.name, this.offset, this.length, {this.text = true});

  final String name;
  final int offset;
  final int length;

  /// True when the field holds readable text, false when it is bytes (the card ID).
  final bool text;

  int get end => offset + length - 1;
  String get range => '${h4(offset)}-${h4(end)}';
}

/// What a meter card says about itself, from the first 64 bytes.
///
/// Worked out from the card files the Elsewedy tools keep in the Vango tree (customer.txt, read_Card_customer.txt and
/// the *_RFID_Card_*.txt sets): 8 real cards from two product lines, Egypt 1PH and Spain 3PH, all with the same
/// layout. Those are the fields the Smart Card Utility's "Read Company ID" shows.
///
/// A card that is not written this way (a fresh applet, a card of 00) simply has no fields, which [looksValid] says.
class CardContent {
  CardContent(this.image);

  /// The identity block, in card order.
  static const fields = [
    CardField('Card ID', 0x00, 10, text: false),
    CardField('Format version', 0x0A, 6),
    CardField('Company ID', 0x10, 10),
    CardField('Firmware version', 0x1A, 6),
    CardField('Region', 0x20, 16),
    CardField('Company', 0x30, 16),
  ];

  /// The format version every sample carries. A different one means the layout may have moved.
  static const knownFormat = '1.0.13';

  final Uint8List image;

  Uint8List bytesOf(CardField f) =>
      f.offset + f.length <= image.length ? Hex.sub(image, f.offset, f.length) : Uint8List(0);

  /// The field as text: up to the first 00, with anything unprintable left out. Empty when the field is not text.
  String textOf(CardField f) {
    final b = bytesOf(f);
    final sb = StringBuffer();
    for (final c in b) {
      if (c == 0) break;
      if (c >= 0x20 && c < 0x7F) sb.writeCharCode(c);
    }
    return sb.toString().trim();
  }

  /// What to show for a field: text for the text ones, hex for the card ID.
  String show(CardField f) => f.text ? textOf(f) : Hex.of(bytesOf(f));

  Uint8List get cardId => bytesOf(fields[0]);
  String get formatVersion => textOf(fields[1]);
  String get companyId => textOf(fields[2]);
  String get firmwareVersion => textOf(fields[3]);
  String get region => textOf(fields[4]);
  String get company => textOf(fields[5]);

  /// True when the card carries an identity block at all: a company and a format version that read as text.
  bool get looksValid => companyId.isNotEmpty && formatVersion.isNotEmpty && RegExp(r'^\d+\.\d+\.\d+$').hasMatch(formatVersion);

  /// True when the format version is the one every known card carries.
  bool get knownLayout => formatVersion == knownFormat;

  /// One line for the screen and the report.
  String get summary {
    if (!looksValid) return 'No meter identity block: the first bytes are not a company and a version.';
    final parts = [
      if (companyId.isNotEmpty) companyId,
      if (region.isNotEmpty) region,
      if (firmwareVersion.isNotEmpty) firmwareVersion,
      'card ${Hex.compact(cardId)}',
    ];
    return parts.join('  ·  ');
  }
}
