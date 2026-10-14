import 'dart:convert';
import 'dart:typed_data';

import 'applet.dart';
import 'hex.dart';

/// How to talk to one kind of ISO 7816 card that keeps its data in a transparent binary file.
///
/// The tool was built for the EMG electrometer applet, but every card-specific thing it does on the Read, Write and
/// Block-editor screens is in here: which AID(s) to look for, how to select the file, how to read its ID, the READ
/// and UPDATE BINARY classes and instructions, and how big the file is. Point a profile at another applet and those
/// screens follow it. The console and the Burner already work with any card and ignore the profile.
///
/// It does not cover cards of another shape (MIFARE sector blocks, record files): those need their own support.
class CardProfile {
  const CardProfile({
    required this.name,
    required this.aidHex,
    this.idCommand = '80 08 00 00 0A',
    this.selectFile = '00 A4 00 00 02 30 40',
    this.fileSize = 32768,
    this.readCla = 0x00,
    this.readIns = 0xB0,
    this.writeCla = 0x00,
    this.writeIns = 0xD6,
    this.builtIn = false,
  });

  /// The EMG electrometer applet, exactly as the tool has always talked to it. This is the default profile, so nothing
  /// changes for the EMG card.
  static const emg = CardProfile(
    name: 'EMG electrometer',
    aidHex: AppletAid.defaultHex,
    builtIn: true,
  );

  /// A starting point for a card whose applet is the file itself (no separate SELECT of an EF), read and written with
  /// the standard binary commands.
  static const plainBinary = CardProfile(
    name: 'Plain binary file (no EF select)',
    aidHex: 'A0 00 00 00 00',
    selectFile: '',
    builtIn: true,
  );

  static const builtInProfiles = [emg, plainBinary];

  final String name;

  /// The AID list this profile puts in the box: the applet(s) a phone would try, in order.
  final String aidHex;

  /// The command that reads the card's own ID (GET UID on the EMG card). Empty when the card has none.
  final String idCommand;

  /// The command that selects the file to read and write. Empty when selecting the applet already opens it.
  final String selectFile;

  /// How many bytes the file holds, addressed from offset 0.
  final int fileSize;

  final int readCla, readIns, writeCla, writeIns;

  /// True for the profiles that ship with the app, which cannot be deleted.
  final bool builtIn;

  int get blockCount => (fileSize + 255) ~/ 256;
  int get lastOffset => fileSize - 1;

  bool get hasIdCommand => idCommand.trim().isNotEmpty;
  bool get hasSelectFile => selectFile.trim().isNotEmpty;

  /// READ BINARY of [le] bytes at [offset]: "CLA INS P1 P2 Le", P1 P2 the offset.
  String readCommand(int offset, int le) =>
      '${h2(readCla)} ${h2(readIns)} ${h2((offset >> 8) & 0xFF)} ${h2(offset & 0xFF)} ${h2(le & 0xFF)}';

  /// UPDATE BINARY of [data] at [offset]: CLA INS P1 P2 Lc data.
  Uint8List writeCommand(int offset, Uint8List data) => Hex.concat([
        [writeCla, writeIns, (offset >> 8) & 0xFF, offset & 0xFF, data.length],
        data,
      ]);

  /// Why this profile is not usable, or null when it is. Checked before it is saved or used.
  String? get problem {
    try {
      final aids = IosAidsText(aidHex);
      if (aids.isEmpty) return 'The profile needs at least one AID.';
    } on FormatException catch (e) {
      return 'The AID list is not hex: ${e.message}';
    }
    for (final (label, cmd) in [('ID command', idCommand), ('SELECT file', selectFile)]) {
      if (cmd.trim().isEmpty) continue;
      try {
        if (Hex.parse(cmd).length < 4) return '$label must be a full APDU (at least CLA INS P1 P2).';
      } on FormatException catch (e) {
        return '$label is not hex: ${e.message}';
      }
    }
    if (fileSize < 16 || fileSize > 0x10000) return 'The file size must be between 16 and 65536 bytes.';
    return null;
  }

  CardProfile copyWith({
    String? name,
    String? aidHex,
    String? idCommand,
    String? selectFile,
    int? fileSize,
    int? readCla,
    int? readIns,
    int? writeCla,
    int? writeIns,
  }) =>
      CardProfile(
        name: name ?? this.name,
        aidHex: aidHex ?? this.aidHex,
        idCommand: idCommand ?? this.idCommand,
        selectFile: selectFile ?? this.selectFile,
        fileSize: fileSize ?? this.fileSize,
        readCla: readCla ?? this.readCla,
        readIns: readIns ?? this.readIns,
        writeCla: writeCla ?? this.writeCla,
        writeIns: writeIns ?? this.writeIns,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'aidHex': aidHex,
        'idCommand': idCommand,
        'selectFile': selectFile,
        'fileSize': fileSize,
        'readCla': readCla,
        'readIns': readIns,
        'writeCla': writeCla,
        'writeIns': writeIns,
      };

  static CardProfile fromJson(Map<String, dynamic> j) => CardProfile(
        name: j['name'] as String? ?? 'Card',
        aidHex: j['aidHex'] as String? ?? AppletAid.defaultHex,
        idCommand: j['idCommand'] as String? ?? '80 08 00 00 0A',
        selectFile: j['selectFile'] as String? ?? '00 A4 00 00 02 30 40',
        fileSize: (j['fileSize'] as num?)?.toInt() ?? 32768,
        readCla: (j['readCla'] as num?)?.toInt() ?? 0x00,
        readIns: (j['readIns'] as num?)?.toInt() ?? 0xB0,
        writeCla: (j['writeCla'] as num?)?.toInt() ?? 0x00,
        writeIns: (j['writeIns'] as num?)?.toInt() ?? 0xD6,
      );

  static String encode(List<CardProfile> profiles) =>
      jsonEncode([for (final p in profiles.where((p) => !p.builtIn)) p.toJson()]);

  static List<CardProfile> decode(String text) {
    try {
      final list = jsonDecode(text) as List;
      return [for (final j in list) fromJson(j as Map<String, dynamic>)];
    } catch (_) {
      return const [];
    }
  }
}

/// Reads the AIDs out of a list the way the AID box does, so a profile can be checked without the UI.
class IosAidsText {
  IosAidsText(String text) {
    for (final token in text.split(RegExp(r'[,;\r\n]+'))) {
      final t = token.trim();
      if (t.isEmpty) continue;
      aids.add(Hex.parse(t)); // throws FormatException when not hex
    }
  }

  final List<Uint8List> aids = [];
  bool get isEmpty => aids.isEmpty;
}
