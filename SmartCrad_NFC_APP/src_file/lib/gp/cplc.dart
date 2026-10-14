import 'dart:typed_data';

import '../card/card_channel.dart';
import '../core/apdu.dart';
import '../core/errors.dart';
import '../core/hex.dart';

/// The Card Production Life Cycle data: what the chip maker burned into the card and nobody can change.
///
/// It is the one number that names a physical card for good. The other two do not:
/// - the contactless UID is random at every tap on this card, so it names the tap;
/// - the applet's card ID (GET UID 80 08) is made afresh by every install, so it names the installation.
///
/// The card answers it with the card manager simply selected, outside any secure channel, which is how it is read
/// here: `80 CA 9F 7F 00`.
class Cplc {
  Cplc(this.bytes);

  /// The 42 bytes of the field itself, without the 9F 7F tag and its length.
  final Uint8List bytes;

  static const length = 42;

  /// The command that asks for it.
  static final getData = Hex.parse('80 CA 9F 7F 00');

  /// Reads it off a card whose card manager is selected. Null when the card does not keep it.
  static Future<Cplc?> read(CardChannel channel) async {
    try {
      final r = ResponseApdu.fromRaw(await channel.transmit(getData));
      return r.sw == 0x9000 ? parse(r.data) : null;
    } on CardException {
      return null; // a card that will not say is not a reason to stop
    }
  }

  /// Takes the 42 bytes out of what GET DATA answered, with or without the 9F 7F tag in front. Null when it is not
  /// CPLC data at all.
  static Cplc? parse(Uint8List data) {
    var d = data;
    if (d.length >= 3 && d[0] == 0x9F && d[1] == 0x7F) d = Hex.sub(d, 3, d.length - 3);
    return d.length >= length ? Cplc(Hex.sub(d, 0, length)) : null;
  }

  Uint8List _at(int offset, int count) => Hex.sub(bytes, offset, count);

  Uint8List get icFabricator => _at(0, 2);
  Uint8List get icType => _at(2, 2);
  Uint8List get osId => _at(4, 2);
  Uint8List get osReleaseDate => _at(6, 2);
  Uint8List get osReleaseLevel => _at(8, 2);
  Uint8List get icFabricationDate => _at(10, 2);

  /// The chip's own serial number, set when it was made.
  Uint8List get icSerial => _at(12, 4);

  /// Which batch the chip came from. Serial numbers are unique inside a batch, so the two together name the chip.
  Uint8List get icBatch => _at(16, 2);

  Uint8List get icModuleFabricator => _at(18, 2);
  Uint8List get icModulePackagingDate => _at(20, 2);
  Uint8List get iccManufacturer => _at(22, 2);
  Uint8List get icEmbeddingDate => _at(24, 2);
  Uint8List get icPrePersonalizer => _at(26, 2);
  Uint8List get icPrePersonalizationDate => _at(28, 2);
  Uint8List get icPrePersonalizationEquipment => _at(30, 4);
  Uint8List get icPersonalizer => _at(34, 2);
  Uint8List get icPersonalizationDate => _at(36, 2);
  Uint8List get icPersonalizationEquipment => _at(38, 4);

  /// Serial number and batch together, as one word of 12 hex digits: the card's fixed name.
  String get chipId => Hex.compact(Hex.concat([icSerial, icBatch]));

  /// The chip maker, when it is one whose number is well known.
  String get fabricator => switch (Hex.compact(icFabricator)) {
        '4790' => 'NXP',
        '4090' => 'NXP',
        '2050' => 'Infineon',
        '3B00' => 'Samsung',
        '4250' => 'Thales / Gemalto',
        _ => '',
      };

  /// Every field with its name, in card order, for a report.
  List<(String, String)> get fields => [
        ('IC fabricator', '${Hex.of(icFabricator)}${fabricator.isEmpty ? '' : '  ($fabricator)'}'),
        ('IC type', Hex.of(icType)),
        ('Operating system ID', Hex.of(osId)),
        ('OS release date', Hex.of(osReleaseDate)),
        ('OS release level', Hex.of(osReleaseLevel)),
        ('IC fabrication date', Hex.of(icFabricationDate)),
        ('IC serial number', Hex.of(icSerial)),
        ('IC batch identifier', Hex.of(icBatch)),
        ('IC module fabricator', Hex.of(icModuleFabricator)),
        ('IC module packaging date', Hex.of(icModulePackagingDate)),
        ('ICC manufacturer', Hex.of(iccManufacturer)),
        ('IC embedding date', Hex.of(icEmbeddingDate)),
        ('IC pre-personalizer', Hex.of(icPrePersonalizer)),
        ('IC pre-personalization date', Hex.of(icPrePersonalizationDate)),
        ('IC pre-personalization equipment', Hex.of(icPrePersonalizationEquipment)),
        ('IC personalizer', Hex.of(icPersonalizer)),
        ('IC personalization date', Hex.of(icPersonalizationDate)),
        ('IC personalization equipment', Hex.of(icPersonalizationEquipment)),
      ];
}
