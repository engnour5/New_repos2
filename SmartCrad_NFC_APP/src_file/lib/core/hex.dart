import 'dart:typed_data';

/// Hex text helpers.
class Hex {
  Hex._();

  /// "00 A4 04 00" style.
  static String of(List<int>? bytes, [int offset = 0, int? count]) {
    if (bytes == null) return '';
    final n = count ?? bytes.length - offset;
    if (n <= 0) return '';
    final sb = StringBuffer();
    for (var i = 0; i < n; i++) {
      if (i > 0) sb.write(' ');
      sb.write(h2(bytes[offset + i]));
    }
    return sb.toString();
  }

  /// "00A40400" style.
  static String compact(List<int>? bytes) => of(bytes).replaceAll(' ', '');

  /// Only the first bytes, for long answers in the log.
  static String brief(List<int>? bytes, int max) {
    if (bytes == null || bytes.isEmpty) return '';
    if (bytes.length <= max) return of(bytes);
    return '${of(bytes, 0, max)} ... (${bytes.length} bytes)';
  }

  /// Reads hex digits. Spaces, commas, colons and dashes are ignored.
  static Uint8List parse(String text) {
    final digits = StringBuffer();
    for (final unit in text.codeUnits) {
      if (_isHex(unit)) {
        digits.writeCharCode(unit);
      } else if (String.fromCharCode(unit).trim().isEmpty || unit == 0x2C || unit == 0x3A || unit == 0x2D) {
        continue;
      } else {
        throw FormatException("'${String.fromCharCode(unit)}' is not a hex digit.");
      }
    }
    final s = digits.toString();
    if (s.length.isOdd) throw FormatException('Odd number of hex digits (${s.length}).');
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static bool _isHex(int u) => (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66);

  static Uint8List sub(List<int> bytes, int offset, int count) =>
      Uint8List.fromList(bytes.sublist(offset, offset + count));

  static Uint8List concat(List<List<int>> parts) {
    final b = BytesBuilder(copy: false);
    for (final p in parts) {
      b.add(p);
    }
    return b.toBytes();
  }

  static bool same(List<int>? a, List<int>? b) {
    if (a == null || b == null) return identical(a, b);
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The bytes as ASCII text, or null when most of them are not printable.
  static String? ascii(List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    var printable = 0;
    final sb = StringBuffer();
    for (final b in bytes) {
      final p = b >= 0x20 && b < 0x7F;
      if (p) printable++;
      sb.write(p ? String.fromCharCode(b) : '.');
    }
    return printable * 2 >= bytes.length ? sb.toString() : null;
  }
}

String h2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

String h4(int v) => v.toRadixString(16).padLeft(4, '0').toUpperCase();
