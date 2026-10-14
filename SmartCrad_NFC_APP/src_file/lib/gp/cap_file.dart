import 'dart:io';
import 'dart:typed_data';

import '../core/hex.dart';

/// A Java Card CAP file: a ZIP whose entries are the components of one package.
///
/// To load it onto a card, the components go into the Load File Data Block in the order the Java Card VM spec gives.
/// Descriptor.cap and Debug.cap are not loaded: they only help tools and debuggers.
class CapFile {
  CapFile._(this.path, this._components, this.packageAid, this.packageVersion, this.appletAids);

  /// The components that are loaded, in the order they must be sent.
  static const loadOrder = [
    'Header',
    'Directory',
    'Import',
    'Applet',
    'Class',
    'Method',
    'StaticField',
    'Export',
    'ConstantPool',
    'RefLocation',
  ];

  final String path;
  final Map<String, Uint8List> _components;

  /// The AID of the package itself, from Header.cap. DELETE works on this one.
  final Uint8List packageAid;

  /// "major.minor" of the package, from Header.cap.
  final String packageVersion;

  /// The applets the package defines, from Applet.cap. One of them is installed as an instance.
  final List<Uint8List> appletAids;

  String get name => path.split(RegExp(r'[\\/]')).last;

  Iterable<String> get componentNames => loadOrder.where(_components.containsKey);

  int get componentBytes => componentNames.fold(0, (n, c) => n + _components[c]!.length);

  static Future<CapFile> read(String path) async => parse(path, await File(path).readAsBytes());

  static CapFile parse(String path, Uint8List bytes) {
    final entries = _unzip(bytes);
    final components = <String, Uint8List>{};
    for (final e in entries.entries) {
      final file = e.key.split('/').last;
      if (!file.toLowerCase().endsWith('.cap')) continue;
      final base = file.substring(0, file.length - 4);
      for (final known in [...loadOrder, 'Descriptor', 'Debug']) {
        if (base.toLowerCase() == known.toLowerCase()) components[known] = e.value;
      }
    }
    final header = components['Header'];
    if (header == null) {
      throw FormatException('$path is not a CAP file: it has no Header.cap component.');
    }
    // Header.cap: tag(1) size(2) magic(4) minor(1) major(1) flags(1) pkg.minor(1) pkg.major(1) aidLen(1) aid(n)
    if (header.length < 14 || Hex.compact(Hex.sub(header, 3, 4)) != 'DECAFFED') {
      throw FormatException('$path has a Header.cap without the DECAFFED magic number.');
    }
    final aidLength = header[12];
    if (header.length < 13 + aidLength) throw FormatException('$path has a Header.cap that stops inside the package AID.');
    final packageAid = Hex.sub(header, 13, aidLength);
    final version = '${header[11]}.${header[10]}';

    final applets = <Uint8List>[];
    final applet = components['Applet'];
    if (applet != null && applet.length > 3) {
      // Applet.cap: tag(1) size(2) count(1) then per applet: aidLen(1) aid(n) installMethodOffset(2)
      var p = 4;
      for (var i = 0; i < applet[3] && p < applet.length; i++) {
        final n = applet[p];
        if (p + 1 + n > applet.length) break;
        applets.add(Hex.sub(applet, p + 1, n));
        p += 1 + n + 2;
      }
    }
    return CapFile._(path, components, packageAid, version, applets);
  }

  /// The Load File Data Block: tag C4, its BER length, then the components in load order.
  Uint8List loadFileDataBlock() {
    final body = Hex.concat([for (final c in componentNames) _components[c]!]);
    return Hex.concat([
      [0xC4],
      _berLength(body.length),
      body,
    ]);
  }

  /// Splits the Load File Data Block into the chunks the LOAD commands carry.
  List<Uint8List> loadBlocks({int blockSize = 240}) {
    final all = loadFileDataBlock();
    return [
      for (var o = 0; o < all.length; o += blockSize)
        Hex.sub(all, o, o + blockSize > all.length ? all.length - o : blockSize),
    ];
  }

  static List<int> _berLength(int n) {
    if (n < 0x80) return [n];
    if (n <= 0xFF) return [0x81, n];
    return [0x82, n >> 8, n & 0xFF];
  }
}

// ------------------------------------------------------------------ the smallest ZIP reader that reads a CAP

/// Reads a ZIP through its central directory. Stored and deflated entries only, which is all a CAP file uses.
Map<String, Uint8List> _unzip(Uint8List z) {
  final end = _findEndOfCentralDirectory(z);
  if (end < 0) throw const FormatException('Not a ZIP file: the end-of-central-directory record is missing.');
  final data = ByteData.sublistView(z);
  final count = data.getUint16(end + 10, Endian.little);
  var p = data.getUint32(end + 16, Endian.little);
  final out = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    if (p + 46 > z.length || data.getUint32(p, Endian.little) != 0x02014b50) {
      throw const FormatException('The ZIP central directory is damaged.');
    }
    final method = data.getUint16(p + 10, Endian.little);
    final compressed = data.getUint32(p + 20, Endian.little);
    final nameLength = data.getUint16(p + 28, Endian.little);
    final extraLength = data.getUint16(p + 30, Endian.little);
    final commentLength = data.getUint16(p + 32, Endian.little);
    final localOffset = data.getUint32(p + 42, Endian.little);
    final name = String.fromCharCodes(Uint8List.sublistView(z, p + 46, p + 46 + nameLength));
    if (data.getUint32(localOffset, Endian.little) != 0x04034b50) {
      throw FormatException('The ZIP entry $name has no local header.');
    }
    final start = localOffset + 30 + data.getUint16(localOffset + 26, Endian.little) + data.getUint16(localOffset + 28, Endian.little);
    final raw = Uint8List.sublistView(z, start, start + compressed);
    out[name] = switch (method) {
      0 => Uint8List.fromList(raw),
      8 => Uint8List.fromList(ZLibCodec(raw: true).decode(raw)),
      _ => throw FormatException('The ZIP entry $name uses compression method $method, which this reader does not do.'),
    };
    p += 46 + nameLength + extraLength + commentLength;
  }
  return out;
}

int _findEndOfCentralDirectory(Uint8List z) {
  final data = ByteData.sublistView(z);
  final lowest = z.length - 22 - 0xFFFF;
  for (var p = z.length - 22; p >= (lowest < 0 ? 0 : lowest); p--) {
    if (data.getUint32(p, Endian.little) == 0x06054b50) return p;
  }
  return -1;
}
