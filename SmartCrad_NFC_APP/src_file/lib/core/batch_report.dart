import '../gp/batch_burn.dart';
import '../gp/cplc.dart';
import 'html_theme.dart';

/// Everything one Auto load run produced, as a web page you can keep: how many cards were burned, and the card ID of
/// every one of them.
class BatchReportInput {
  BatchReportInput({
    required this.generatedAt,
    required this.batch,
    required this.reader,
    required this.capName,
    required this.packageAid,
    required this.instanceAid,
    required this.defaultSelected,
    required this.deleteFirst,
    this.force = false,
    this.startedAt,
    this.simulated = false,
  });

  final DateTime generatedAt;
  final BatchBurn batch;
  final String reader;
  final String capName;
  final String packageAid;
  final String instanceAid;
  final bool defaultSelected;
  final bool deleteFirst;

  /// True when the run deleted any applet already using the AID (and any default-selected one) before installing.
  final bool force;
  final DateTime? startedAt;

  /// True when the run went to the simulated card, so a page of greens cannot be mistaken for a tray of real cards.
  final bool simulated;
}

/// The page itself. Every card that was burned is listed with its card ID, so the run can be checked afterwards.
String buildBatchReport(BatchReportInput r) {
  final b = StringBuffer();
  final batch = r.batch;
  final when = _date(r.generatedAt);
  final cls = batch.failed > 0 ? (batch.ok > 0 ? 'warn' : 'fail') : 'ok';
  final seconds = batch.cards.fold<double>(0, (n, c) => n + c.seconds);

  b.write('<!doctype html><html lang="en"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>Auto load report ${_e(when)}</title><style>$_css</style></head><body>');
  b.write('<header><div class="wrap"><div class="brand"><span class="logo">&#x25CE;</span> NFC Card Tester</div>'
      '<h1>Auto load report</h1><p>${_e(r.capName)} burned onto one card after another &middot; ${_e(when)}</p>'
      '</div></header><main class="wrap">');

  // the answer, first
  b.write('<section class="verdict $cls"><div class="big">${batch.ok} card${batch.ok == 1 ? '' : 's'} burned</div>');
  if (r.simulated) {
    b.write('<p class="sim">This ran against the SIMULATED card, not real cards. It says nothing about any hardware.</p>');
  }
  b.write('<p>${_e(_summary(batch))}</p></section>');

  // tiles
  b.write('<section class="tiles">');
  b.write(_tile('Cards burned', '${batch.ok}', 'loaded and installed', batch.ok > 0 ? 'ok' : 'info'));
  b.write(_tile('Failed', '${batch.failed}', batch.failed == 0 ? 'none' : 'see the list below',
      batch.failed == 0 ? 'info' : 'fail'));
  b.write(_tile('Cards in all', '${batch.done}', 'put on the reader', 'info'));
  if (seconds > 0) {
    b.write(_tile('Burning time', '${seconds.toStringAsFixed(1)} s',
        batch.done == 0 ? '' : '${(seconds / batch.done).toStringAsFixed(1)} s a card', 'info'));
  }
  b.write('</section>');

  // every card, with its ID: the point of the page
  b.write('<section class="card"><h2>Every card</h2>');
  if (batch.cards.isEmpty) {
    b.write('<p class="muted">No card was put on the reader.</p>');
  } else {
    // how many times each chip ID was seen, and a colour for every chip seen more than once, so the same physical
    // card stands out wherever it appears on the page
    final chipCount = <String, int>{};
    for (final c in batch.cards) {
      if (c.chipId.isNotEmpty) chipCount[c.chipId] = (chipCount[c.chipId] ?? 0) + 1;
    }
    final chipColor = <String, int>{}; // repeated chip ID -> colour index, in order of first appearance
    for (final c in batch.cards) {
      final id = c.chipId;
      if (id.isNotEmpty && (chipCount[id] ?? 0) > 1 && !chipColor.containsKey(id)) {
        chipColor[id] = chipColor.length;
      }
    }
    // the chip ID as it appears in the table (coloured, with a "x N" count) or inline in the list (coloured only)
    String chipCell(String id) {
      if (id.isEmpty) return '<span class="muted">not kept</span>';
      final n = chipCount[id] ?? 0;
      if (n <= 1) return _e(id);
      return '<span class="dupc dupc${chipColor[id]! % _dupColors}">${_e(id)}</span> <span class="dupmark">&#215;$n</span>';
    }
    String chipInline(String id) => (chipCount[id] ?? 0) <= 1
        ? _e(id)
        : '<span class="dupc dupc${chipColor[id]! % _dupColors}">${_e(id)}</span>';

    b.write('<p class="muted">The <b>chip ID</b> is burned into the card when it is made: it is the same before and '
        'after a burn, and the same at every tap, so it is the number that names a card for good.'
        '${chipColor.isEmpty ? '' : ' A chip ID seen more than once is <b>coloured</b>; cards that share a colour are '
            'the same physical card.'}</p>');
    b.write('<div class="scroll"><table><thead><tr><th>No.</th><th>Result</th>'
        '<th>Chip ID (CPLC)</th><th>Time</th><th>Took</th></tr></thead><tbody>');
    for (final c in batch.cards) {
      final repeated = (chipCount[c.chipId] ?? 0) > 1;
      b.write('<tr class="${c.ok ? 'ok' : 'fail'}${repeated ? ' dup' : ''}"><td><b>${c.number}</b></td>'
          '<td>${_pill(c.ok ? 'OK' : 'FAILED')}</td>'
          '<td class="mono big-id">${chipCell(c.chipId)}</td>'
          '<td class="mono">${_e(_time(c.finishedAt))}</td>'
          '<td class="mono">${c.seconds.toStringAsFixed(1)} s</td></tr>');
      if (!c.ok) {
        b.write('<tr class="fail"><td></td><td colspan="4" class="why">${_e(c.message)}</td></tr>');
      }
    }
    b.write('</tbody></table></div>');

    final chips = [for (final c in batch.cards) if (c.ok && c.chipId.isNotEmpty) c.chipId];
    if (chips.isNotEmpty) {
      b.write('<h3>The chip IDs on their own</h3>'
          '<p class="muted">One per line, so they can be pasted into a list or a spreadsheet.</p>'
          '<pre class="ids">${chips.map(chipInline).join('\n')}</pre>');
    }
    if (chipColor.isNotEmpty) {
      final parts = <String>[];
      for (final id in chipColor.keys) {
        final nums = [for (final c in batch.cards) if (c.chipId == id) c.number];
        parts.add('<span class="dupc dupc${chipColor[id]! % _dupColors}">${_e(id)}</span> '
            '(card${nums.length == 1 ? '' : 's'} ${nums.join(', ')})');
      }
      b.write('<p class="line warn">A chip ID shown more than once means the same card was burned again: '
          '${parts.join('; ')}.</p>');
    }
    // the chip of the last card, in full, so the fields can be checked once
    final chip = batch.cards.reversed.map((c) => c.chip).whereType<Cplc>().firstOrNull;
    if (chip != null) {
      b.write('<h3>What the chip says about itself (the last card)</h3><div class="scroll"><table class="kv">');
      for (final (name, value) in chip.fields) {
        b.write(_kv(name, value, mono: true));
      }
      b.write('</table></div>');
    }
  }
  b.write('</section>');

  // what every card was given
  b.write('<section class="card"><h2>What every card was given</h2><table class="kv">');
  b.write(_kv('CAP file', r.capName));
  b.write(_kv('Package AID', r.packageAid, mono: true));
  b.write(_kv('Installed as', r.instanceAid, mono: true));
  b.write(_kv('Default selected', r.defaultSelected ? 'yes: the card picks this applet after every power-up' : 'no'));
  b.write(_kv('Delete the package first',
      r.force ? 'Force: any applet already using the AID was deleted first, with its data' : r.deleteFirst ? 'yes, with its data' : 'no'));
  b.write(_kv('Reader', r.reader));
  if (r.startedAt != null) b.write(_kv('Started', _date(r.startedAt!)));
  b.write(_kv('Finished', when));
  if (batch.stopped != null) b.write(_kv('The run ended because', batch.stopped!));
  b.write('</table></section>');

  b.write('</main><footer class="wrap">Made by NFC Card Tester on ${_e(when)}. '
      'The card manager keys are never written to this page.</footer></body></html>');
  return b.toString();
}

String _summary(BatchBurn b) {
  if (b.done == 0) return 'No card was put on the reader.';
  if (b.failed == 0) return 'Every card that went on the reader took the applet. Each one is listed below by its chip ID.';
  if (b.ok == 0) return 'No card took the applet. The list below says why for each one.';
  return '${b.ok} of ${b.done} cards took the applet; ${b.failed} did not. The list below says why.';
}

String _tile(String label, String value, String text, String cls) =>
    '<div class="tile $cls"><div class="label">${_e(label)}</div><div class="value">${_e(value)}</div>'
    '<div class="text">${_e(text)}</div></div>';

String _kv(String k, String v, {bool mono = false}) =>
    '<tr><th>${_e(k)}</th><td${mono ? ' class="mono"' : ''}>${_e(v)}</td></tr>';

String _pill(String result) => '<span class="pill p-${_e(result)}">${_e(result)}</span>';

/// How many colours the repeated-chip palette has; chips past this many repeats wrap around to the start.
const _dupColors = 6;

String _e(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');

String _two(int v) => v.toString().padLeft(2, '0');

String _time(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String _date(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)} ${_time(t)}';

const _css = '''
$htmlPalette
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:0 20px}
header{background:linear-gradient(120deg,#4f6bed,#22d3ee);color:#fff;padding:26px 0 30px;margin-bottom:22px}
header h1{margin:6px 0 2px;font-size:31px}header p{margin:0;opacity:.9}.brand{font-weight:700;opacity:.9}
.logo{display:inline-block;margin-right:6px}
.verdict{border-radius:18px;padding:20px 24px;margin-bottom:18px;border:1px solid var(--line)}
.verdict .big{font-size:30px;font-weight:800}
.verdict p{margin:6px 0 0;max-width:80ch}
.verdict p.sim{font-weight:800;color:var(--warn);background:rgba(251,191,36,.14);border:1px solid rgba(251,191,36,.5);border-radius:10px;padding:8px 12px}
.verdict.ok{background:rgba(34,197,94,.12);border-color:rgba(34,197,94,.45)}.verdict.ok .big{color:var(--ok)}
.verdict.warn{background:rgba(251,191,36,.12);border-color:rgba(251,191,36,.45)}.verdict.warn .big{color:var(--warn)}
.verdict.fail{background:rgba(248,113,113,.12);border-color:rgba(248,113,113,.45)}.verdict.fail .big{color:var(--fail)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px;margin-bottom:18px}
.tile{background:var(--panel);border:1px solid var(--line);border-left:6px solid var(--info);border-radius:16px;padding:13px 16px}
.tile .label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.tile .value{font-size:25px;font-weight:800;margin:2px 0}
.tile .text{color:var(--muted);font-size:12.5px}
.tile.ok{border-left-color:var(--ok)}.tile.ok .value{color:var(--ok)}
.tile.fail{border-left-color:var(--fail)}.tile.fail .value{color:var(--fail)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:18px 20px;margin-bottom:18px}
.card h2{margin:0 0 12px;font-size:20px}
.card h3{margin:18px 0 8px;font-size:13px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
.muted{color:var(--muted)}
.line{font-weight:700;padding:10px 14px;border-radius:12px;margin:10px 0 0}
.line.warn{background:rgba(251,191,36,.12);color:var(--warn)}
.scroll{overflow-x:auto}
table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
thead th{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em;white-space:nowrap}
tr.ok td:first-child{color:var(--ok)}
tr.fail td{background:rgba(248,113,113,.07)}
td.why{color:var(--fail)}
.mono{font-family:Consolas,"Courier New",monospace;font-size:12.5px;white-space:nowrap}
.big-id{font-size:13.5px;font-weight:700;color:var(--accent)}
.pill{display:inline-block;padding:1px 9px;border-radius:999px;font-size:11.5px;font-weight:700}
.p-OK{background:rgba(34,197,94,.16);color:var(--ok)}
.p-FAILED{background:rgba(248,113,113,.16);color:var(--fail)}
table.kv th{width:230px;color:var(--muted);font-weight:600}
pre.ids{background:var(--bg);border:1px solid var(--line);border-radius:12px;padding:12px 14px;overflow-x:auto;
  font-family:Consolas,"Courier New",monospace;font-size:13px;color:var(--accent);margin:0;line-height:1.7}
footer{color:var(--muted);font-size:12.5px;padding:10px 0 26px}
/* repeated chip IDs: the same physical card seen again. Cards that share a colour are the same chip. */
tr.ok.dup td{background:rgba(148,163,184,.07)}
.dupc{font-weight:700;border-radius:5px;padding:0 5px}
.dupmark{font-size:10.5px;font-weight:800;color:var(--muted);margin-left:2px}
.dupc0{color:#f59e0b;background:rgba(245,158,11,.16)}
.dupc1{color:#22d3ee;background:rgba(34,211,238,.16)}
.dupc2{color:#c084fc;background:rgba(192,132,252,.16)}
.dupc3{color:#f472b6;background:rgba(244,114,182,.16)}
.dupc4{color:#60a5fa;background:rgba(96,165,250,.16)}
.dupc5{color:#fb923c;background:rgba(251,146,60,.16)}
@media print{
.dupc0{color:#b45309;background:#fde68a}.dupc1{color:#0e7490;background:#a5f3fc}
.dupc2{color:#7e22ce;background:#e9d5ff}.dupc3{color:#be185d;background:#fbcfe8}
.dupc4{color:#1d4ed8;background:#bfdbfe}.dupc5{color:#c2410c;background:#fed7aa}
}
''';
