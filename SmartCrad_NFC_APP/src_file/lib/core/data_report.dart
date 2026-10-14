import 'card_reader.dart';
import 'hex.dart';
import 'html_theme.dart';
import 'platform.dart';

/// Builds the HTML report of the data read from the card: the result, what was not read and why, a map of the 256-byte
/// blocks, then every block as offset / hex / ASCII. Bytes that were not read show as "--". Blocks that are all 00 or all
/// FF are folded, so the data stands out.
String buildDataReport(CardReadResult r, {required String reader, String? atr, String? uid}) {
  final b = StringBuffer();
  final when = _date(r.time);
  final kinds = r.blockKinds;
  final dataBlocks = kinds.where((k) => k == 'data').length;
  final crc = r.crc.toRadixString(16).padLeft(8, '0').toUpperCase();
  final cls = r.ok ? (r.warnings.isEmpty ? 'ok' : 'warn') : 'fail';

  b.write('<!doctype html><html lang="en"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>Card data ${_e(when)}</title><style>$_css</style></head><body>');
  b.write('<header><div class="wrap"><div class="brand">NFC Card Tester</div><h1>Card data report</h1>'
      '<p>${_e(r.platform.short)} rules &middot; ${_e(reader)} &middot; ${_e(when)}</p></div></header><main class="wrap">');

  b.write('<p class="result $cls">${r.ok ? '&#10004;' : '&#9888;'} ${_e(r.message)}</p>');

  b.write('<section class="tiles">');
  b.write(_tile('Bytes read', '${r.bytesRead}', 'of ${r.expected} (${(r.bytesRead / 1024).toStringAsFixed(2)} KB)',
      r.ok ? 'ok' : 'fail'));
  b.write(_tile('Not read', '${r.expected - r.bytesRead}', r.bytesRead == r.expected ? 'bytes' : 'bytes, see below',
      r.bytesRead == r.expected ? 'ok' : 'fail'));
  b.write(_tile('Time', '${r.seconds.toStringAsFixed(2)} s', '${r.kbPerSecond.toStringAsFixed(1)} KB/s, ${r.commands} commands', 'info'));
  b.write(_tile('Blocks with data', '$dataBlocks', 'of ${r.blockCount} blocks (256 bytes each)', 'info'));
  b.write(_tile('CRC-32', crc, 'of the bytes read, to compare dumps', 'info'));
  b.write('</section>');

  final missing = r.missing;
  if (missing.isNotEmpty && r.bytesRead > 0) {
    b.write('<section class="card bad"><h2>Not read <small>${missing.length} part${missing.length == 1 ? '' : 's'}; '
        'the bytes show as -- in the data below</small></h2><table class="kv"><thead><tr><th>Offsets</th><th>Bytes</th>'
        '<th>Why</th></tr></thead><tbody>');
    for (final m in missing) {
      b.write('<tr><td class="mono"><a href="#b${h2(m.$1 >> 8)}">${h4(m.$1)}-${h4(m.$2)}</a></td><td>${m.$2 - m.$1 + 1}</td>'
          '<td>${_e(m.$3)}</td></tr>');
    }
    b.write('</tbody></table></section>');
  }
  if (r.warnings.isNotEmpty) {
    b.write('<section class="card warnbox"><h2>Warnings</h2><ul>');
    for (final w in r.warnings) {
      b.write('<li>${_e(w)}</li>');
    }
    b.write('</ul></section>');
  }

  b.write('<section class="card"><h2>Read details</h2><table class="kv">');
  b.write(_kv('Reader', reader));
  b.write(_kv('Phone rules', r.platform.short));
  if (atr != null) b.write(_kv('ATR', atr, mono: true));
  if (uid != null) b.write(_kv('NFC UID', uid, mono: true));
  if (r.cardId != null) b.write(_kv('Card ID (GET UID 80 08)', Hex.of(r.cardId), mono: true));
  b.write(_kv('How it was read',
      'SELECT applet, GET UID, SELECT EF 3040 (if one fails the reading still goes on), then READ BINARY of every 256-byte '
      'block from 0000 to 7FFF. A block that fails is noted and the next block is read. A 6C xx answer is read again with '
      'Le = xx; a block that fails with an unexpected answer is read again 16 bytes at a time. If the card stops answering, '
      'it is tapped again. At the end, READ 7FFF with Le 02 checks for data past 7FFF.'));
  b.write(_kv('Expected', '${r.expected} bytes, offsets 0000-${h4(r.expected - 1)}'));
  b.write('</table></section>');

  // block map
  b.write('<section class="card"><h2>Block map <small>each square is 256 bytes; click one to see its data</small></h2><div class="map">');
  for (var i = 0; i < r.blockCount; i++) {
    final kind = i < kinds.length ? kinds[i] : 'missing';
    final id = h2(i);
    final title = 'Block $id, ${h4(i * 256)}-${h4(i * 256 + 255)}: ${_kindText(kind)}';
    b.write('<a class="cell k$kind" href="#b$id" title="${_e(title)}">$id</a>');
  }
  b.write('</div><p class="legend"><span class="cell kdata"></span> data <span class="cell k00"></span> all 00 '
      '<span class="cell kFF"></span> all FF <span class="cell kpartial"></span> partly read '
      '<span class="cell kmissing"></span> not read</p></section>');

  // the data, block by block
  b.write('<section class="card"><h2>Data <small>offset · 16 bytes · ASCII; 00 bytes are dimmed, -- was not read</small></h2>');
  if (r.bytesRead == 0) {
    b.write('<p class="muted">No data was read.</p>');
  } else {
    for (final block in r.blocks) {
      final i = block.index;
      final start = block.start;
      var nonZero = 0;
      for (var j = start; j < start + block.bytes; j++) {
        if (r.image[j] != 0) nonZero++;
      }
      final kind = kinds[i];
      final head = '<span class="bn">Block ${h2(i)}</span> <span class="range">${h4(start)}-${h4(start + 255)}</span> '
          '<span class="tag k$kind">${_kindText(kind)}</span>'
          '${kind == 'data' ? ' <span class="nz">$nonZero non-zero bytes</span>' : ''}'
          '${block.complete ? '' : ' <span class="why">${block.bytes} of 256 bytes read; ${_e(block.problem ?? 'not read')}</span>'}';
      final table = _hexTable(r, start, block.bytes);
      if (kind == '00' || kind == 'FF') {
        b.write('<details class="blk" id="b${h2(i)}"><summary>$head</summary>$table</details>');
      } else {
        b.write('<div class="blk${block.complete ? '' : ' bad'}" id="b${h2(i)}"><h3>$head</h3>$table</div>');
      }
    }
  }
  b.write('</section>');

  b.write('</main><footer class="wrap">Made by NFC Card Tester on ${_e(when)}. Read-only: nothing was written to the card.</footer>'
      '</body></html>');
  return b.toString();
}

/// 16 rows of offset / hex / ASCII for one block; the first [readBytes] bytes were read, the rest show as --.
String _hexTable(CardReadResult r, int start, int readBytes) {
  final b = StringBuffer('<table class="hex"><thead><tr><th>Offset</th><th>');
  for (var c = 0; c < 16; c++) {
    b.write(h2(c));
    b.write(c == 7 ? '&nbsp; ' : ' ');
  }
  b.write('</th><th>ASCII</th></tr></thead><tbody>');
  final readEnd = start + readBytes;
  for (var row = start; row < start + 256; row += 16) {
    b.write('<tr><td class="off">${h4(row)}</td><td class="hx">');
    for (var i = row; i < row + 16; i++) {
      if (i >= readEnd) {
        b.write('<u>--</u>');
      } else {
        final v = r.image[i];
        b.write(v == 0 ? '<i>00</i>' : h2(v));
      }
      b.write(i - row == 7 ? '&nbsp; ' : ' ');
    }
    b.write('</td><td class="asc">');
    for (var i = row; i < row + 16; i++) {
      if (i >= readEnd) {
        b.write('<u>-</u>');
        continue;
      }
      final v = r.image[i];
      if (v >= 0x20 && v < 0x7F) {
        b.write(_e(String.fromCharCode(v)));
      } else {
        b.write('<i>.</i>');
      }
    }
    b.write('</td></tr>');
  }
  b.write('</tbody></table>');
  return b.toString();
}

String _kindText(String kind) => switch (kind) {
      '00' => 'all 00 (empty)',
      'FF' => 'all FF',
      'partial' => 'partly read',
      'missing' => 'not read',
      _ => 'data',
    };

String _tile(String label, String value, String text, String cls) =>
    '<div class="tile $cls"><div class="label">${_e(label)}</div><div class="value">${_e(value)}</div><div class="text">${_e(text)}</div></div>';

String _kv(String k, String v, {bool mono = false}) => '<tr><th>${_e(k)}</th><td${mono ? ' class="mono"' : ''}>${_e(v)}</td></tr>';

String _e(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');

String _date(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

const _css = '''
$htmlPalette
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:1180px;margin:0 auto;padding:0 20px}
header{background:linear-gradient(120deg,#4f6bed,#22d3ee);color:#fff;padding:24px 0 28px;margin-bottom:20px}
header h1{margin:6px 0 2px;font-size:30px}header p{margin:0;opacity:.9}.brand{font-weight:700;opacity:.9}
.result{font-size:17px;font-weight:700;padding:14px 18px;border-radius:14px;margin:0 0 16px}
.result.ok{background:rgba(22,163,74,.13);color:var(--ok);border:1px solid rgba(22,163,74,.4)}
.result.warn{background:rgba(217,119,6,.13);color:var(--warn);border:1px solid rgba(217,119,6,.4)}
.result.fail{background:rgba(220,38,38,.12);color:var(--fail);border:1px solid rgba(220,38,38,.4)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px;margin-bottom:16px}
.tile{background:var(--panel);border:1px solid var(--line);border-left:6px solid var(--data);border-radius:16px;padding:12px 16px}
.tile .label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.tile .value{font-size:24px;font-weight:800;margin:2px 0;font-family:Consolas,"Segoe UI",monospace}
.tile .text{color:var(--muted);font-size:13px}
.tile.ok{border-left-color:var(--ok)}.tile.ok .value{color:var(--ok)}
.tile.fail{border-left-color:var(--fail)}.tile.fail .value{color:var(--fail)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:18px 20px;margin-bottom:16px}
.card.bad{border-color:rgba(220,38,38,.5)}.card.bad h2{color:var(--fail)}
.card.warnbox{border-color:rgba(217,119,6,.5)}.card.warnbox h2{color:var(--warn)}
.card h2{margin:0 0 12px;font-size:19px}.card h2 small{color:var(--muted);font-weight:400;font-size:13px;margin-left:8px}
table{border-collapse:collapse}
table.kv{width:100%}table.kv th,table.kv td{text-align:left;vertical-align:top;padding:7px 9px;border-bottom:1px solid var(--line)}
table.kv th{width:230px;color:var(--muted);font-weight:600}
.mono{font-family:Consolas,"Cascadia Mono",monospace}
a{color:var(--accent)}
ul{margin:4px 0 0;padding-left:20px}li{margin-bottom:4px}
.map{display:grid;grid-template-columns:repeat(16,1fr);gap:4px;max-width:760px}
.cell{display:inline-block;text-align:center;font:11px Consolas,monospace;padding:6px 0;border-radius:6px;text-decoration:none;color:#fff}
.kdata{background:var(--data)}.k00{background:var(--zero);color:var(--muted)}.kFF{background:var(--ff)}
.kpartial{background:transparent;border:2px solid var(--warn);color:var(--warn)}
.kmissing{background:transparent;border:1px dashed var(--fail);color:var(--fail)}
.legend{color:var(--muted);font-size:12px;margin:10px 0 0}.legend .cell{width:16px;height:12px;padding:0;vertical-align:middle;margin:0 4px 0 12px}
.blk{border-top:1px solid var(--line);padding:8px 0}
.blk.bad{background:rgba(220,38,38,.05)}
.blk h3,.blk summary{font-size:14px;margin:4px 0 8px}.blk summary{cursor:pointer}
.bn{font-weight:800}.range{font-family:Consolas,monospace;color:var(--muted);margin-left:6px}
.tag{font-size:11px;font-weight:700;border-radius:99px;padding:1px 9px;margin-left:8px;color:#fff}
.tag.k00{color:var(--muted)}.tag.kpartial,.tag.kmissing{border-radius:99px}
.nz{color:var(--muted);font-size:12px;margin-left:8px}.why{color:var(--fail);font-size:12px;margin-left:8px}
table.hex{font:12.5px/1.55 Consolas,"Cascadia Mono",monospace;margin:2px 0 6px}
table.hex th{color:var(--muted);font-weight:600;text-align:left;padding:2px 12px 2px 0;border-bottom:1px solid var(--line)}
table.hex td{padding:0 14px 0 0;white-space:pre}
table.hex td.off{color:var(--accent);font-weight:700}
table.hex i{font-style:normal;opacity:.35}
table.hex u{text-decoration:none;color:var(--fail);opacity:.8}
.muted{color:var(--muted)}
footer{color:var(--muted);font-size:12px;padding:6px 20px 26px}
@media print{header,.result,.tile,.cell,.tag{-webkit-print-color-adjust:exact;print-color-adjust:exact}details{display:block}}
''';
