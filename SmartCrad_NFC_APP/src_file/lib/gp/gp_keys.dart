import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/hex.dart';

/// The three card-manager keys of a GlobalPlatform key set.
///
/// They are the card's secret: with them an applet can be loaded or deleted, and a wrong one counts against the
/// card manager's try limit. So the tool reads them from a config file you already keep, never writes them to a
/// report, a log or an APDU dump, and shows them masked. They also never travel to the card: only cryptograms do.
class GpKeys {
  GpKeys({required this.enc, required this.mac, required this.dek, this.keyVersion = 0, this.keyId = 0});

  /// The key a GlobalPlatform card leaves the factory with: 40 41 ... 4F, the same for all three.
  factory GpKeys.factoryKey() {
    final k = Hex.parse('404142434445464748494A4B4C4D4E4F');
    return GpKeys(enc: k, mac: k, dek: k);
  }

  /// The "Default test key": the test card's own key set, from PyApduTool's config.ini. The simulated card holds the
  /// same keys, so this one set opens both. Only when no config.ini is found is it the factory key, and [file] is null.
  static ({GpKeys keys, String? file}) defaultTestKey() {
    for (final path in pyApduToolConfigs) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        return (keys: parseConfig(path, _lines(file.readAsBytesSync())), file: path);
      } on FormatException {
        // this config.ini does not hold the three keys: try the next one
      }
    }
    return (keys: GpKeys.factoryKey(), file: null);
  }

  /// Key-ENC: proves who you are, and makes the session encryption key.
  final Uint8List enc;

  /// Key-MAC: makes the session key that signs every command.
  final Uint8List mac;

  /// Key-DEK: encrypts key values; a CAP load does not need it.
  final Uint8List dek;

  final int keyVersion;
  final int keyId;

  bool get usable => enc.length == 16 && mac.length == 16 && dek.length == 16;

  /// What may be shown or written down: how long each key is and the first 2 bytes of a check value, never the key.
  String get masked => '3 keys of ${enc.length} bytes, key version $keyVersion';

  GpKeys copyWith({Uint8List? enc, Uint8List? mac, Uint8List? dek, int? keyVersion, int? keyId}) => GpKeys(
        enc: enc ?? this.enc,
        mac: mac ?? this.mac,
        dek: dek ?? this.dek,
        keyVersion: keyVersion ?? this.keyVersion,
        keyId: keyId ?? this.keyId,
      );

  /// Where PyApduTool keeps its config.ini, the likeliest first. The app sits in the same Tools folder as PyApduTool
  /// (Tools\SmartCrad_NFC_APP\App_file next to Tools\PyApduTool_Release), so it is found wherever that folder is
  /// checked out; the fixed paths are where it has been on this PC.
  static List<String> get pyApduToolConfigs {
    String nextTo(Directory appFolder) => '${appFolder.parent.parent.path}\\PyApduTool_Release\\config.ini';
    return [
      nextTo(File(Platform.resolvedExecutable).parent), // App_file
      nextTo(Directory.current), // src_file, when the tests run
      r'D:\ANSI_Projects\FW\svn\Applet_Smart_Card\Tools\PyApduTool_Release\config.ini',
      r'D:\Applet_Card_G2\gas_electrometer_javaApplet\Tool\PyApduTool_Release\config.ini',
    ];
  }

  /// The PyApduTool config.ini this PC has, or where it would be.
  static String get pyApduToolConfig =>
      pyApduToolConfigs.firstWhere((p) => File(p).existsSync(), orElse: () => pyApduToolConfigs.first);

  /// The tool's own key file, used only when you ask it to keep a copy.
  static String get ownConfig {
    final appData = Platform.environment['APPDATA'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return '$appData\\NFC Card Tester\\gp_keys.ini';
  }

  /// Reads a PyApduTool-style config.ini: a [ControlCenter] section with authkey, cmackey and dekkey.
  static Future<GpKeys> readConfig(String path) async {
    final file = File(path);
    if (!file.existsSync()) throw FileSystemException('No key file here', path);
    return parseConfig(path, _lines(await file.readAsBytes()));
  }

  /// The three keys out of the lines of a config.ini; everything else in it is left alone.
  static GpKeys parseConfig(String path, List<String> lines) {
    final values = <String, String>{};
    var inSection = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        inSection = line.toLowerCase().startsWith('[controlcenter');
        continue;
      }
      if (!inSection || !line.contains('=')) continue;
      final i = line.indexOf('=');
      values[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
    }
    Uint8List key(String name) {
      final text = values[name];
      if (text == null || text.isEmpty) throw FormatException('$path has no "$name" in its [ControlCenter] section.');
      final bytes = Hex.parse(text);
      if (bytes.length != 16) throw FormatException('"$name" in $path is ${bytes.length} bytes; a key is 16.');
      return bytes;
    }

    // only the three keys are needed; a key version is read when the file has one, which PyApduTool's does not
    return GpKeys(
      enc: key('authkey'),
      mac: key('cmackey'),
      dek: key('dekkey'),
      keyVersion: int.tryParse(values['keyversion'] ?? '') ?? 0,
    );
  }

  /// The text of a key file, whichever way it was saved: with or without a byte order mark, any line ends.
  static List<String> _lines(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return const LineSplitter().convert(text.startsWith('\uFEFF') ? text.substring(1) : text);
  }

  /// Writes the keys to the tool's own file, for when you would rather not point at PyApduTool's.
  static Future<String> writeOwnConfig(GpKeys keys) async {
    final file = File(ownConfig);
    await file.parent.create(recursive: true);
    await file.writeAsString('; Card manager keys for the NFC Card Tester. Keep this file private.\r\n'
        '[ControlCenter]\r\n'
        'authkey = ${Hex.of(keys.enc)}\r\n'
        'cmackey = ${Hex.of(keys.mac)}\r\n'
        'dekkey = ${Hex.of(keys.dek)}\r\n'
        'keyversion = ${keys.keyVersion}\r\n');
    return file.path;
  }
}
