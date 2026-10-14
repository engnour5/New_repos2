/// CRC-32 (IEEE 802.3, the one zip uses), to compare card dumps.
int crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = _table[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

final List<int> _table = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});
