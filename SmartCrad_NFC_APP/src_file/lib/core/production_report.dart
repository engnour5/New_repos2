import 'card_test.dart';
import 'html_theme.dart';
import 'platform.dart';
import 'production.dart';

/// Everything one "Run all tests" produced, as a single web page: the verdict first, then each stage, then the detail
/// for both phones. The 32 KB of card data is not repeated here; each read writes its own data report.
class ProductionReportInput {
  ProductionReportInput({
    required this.generatedAt,
    required this.summary,
    required this.reader,
    required this.aidList,
    required this.appletAid,
    this.atr,
    this.cardType,
    this.uid,
    this.historical,
    this.cardId,
    this.seconds = 0,
    this.dataReports = const [],
    this.log = const [],
  });

  final DateTime generatedAt;
  final ProductionSummary summary;
  final String reader;
  final String aidList;
  final String appletAid;
  final String? atr;
  final String? cardType;
  final String? uid;
  final String? historical;
  final String? cardId;
  final double seconds;

  /// The card_data_*.html files the reads wrote, so the hex is one click away instead of inlined.
  final List<String> dataReports;
  final List<String> log;
}

String buildProductionReport(ProductionReportInput r) {
  final s = r.summary;
  final b = StringBuffer();
  final when = _date(r.generatedAt);
  final cls = s.failures > 0 ? 'fail' : (s.warnings > 0 ? 'warn' : 'ok');

  b.write('<!doctype html><html lang="en"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>Card readiness report ${_e(when)}</title><style>$_css</style></head><body>');

  b.write('<header><div class="wrap"><div class="brand"><span class="logo">&#x25CE;</span> NFC Card Tester</div>'
      '<h1>Card readiness report</h1><p>Every test, on both phones &middot; ${_e(when)}</p></div></header><main class="wrap">');

  // the answer, first
  b.write('<section class="verdict $cls"><div class="big">${s.ready ? (s.warnings > 0 ? 'READY, WITH WARNINGS' : 'READY') : 'NOT READY'}</div>');
  if (s.simulated) b.write('<p class="sim">${_e(ProductionSummary.simulatorNote)}</p>');
  b.write('<p>${_e(s.verdict.replaceFirst('${ProductionSummary.simulatorNote} ', ''))}</p></section>');

  // tiles
  b.write('<section class="tiles">');
  b.write(_tile('Checks passed', '${s.stages.length - s.failures - s.warnings} / ${s.stages.length}',
      '${s.failures} failed, ${s.warnings} with warnings', cls));
  if (s.cardSize != null) {
    final ok = s.cardSize == CardTest.fullSize;
    b.write(_tile('Card size', '${s.cardSize} bytes', ok ? 'the whole 32 KB file reads' : 'only ${CardTest.fullSize} bytes passes',
        ok ? 'ok' : 'fail'));
  }
  for (final p in s.platforms) {
    b.write(_tile('${_e(p.platform.short)} unit test', '${p.testPassed} / ${p.testRows.length}',
        '${p.testFailures} failed', p.testFailures == 0 ? 'ok' : 'fail'));
  }
  if (r.seconds > 0) b.write(_tile('Time', '${r.seconds.toStringAsFixed(1)} s', 'for everything', 'info'));
  b.write('</section>');

  // every stage, in order
  b.write('<section class="card"><h2>Every stage</h2><div class="scroll"><table>'
      '<thead><tr><th>Stage</th><th>Result</th><th>What happened</th></tr></thead><tbody>');
  for (final stage in s.stages) {
    b.write('<tr class="${stage.result}"><td><b>${_e(stage.name)}</b></td><td>${_pill(stage.result)}</td>'
        '<td>${_e(stage.detail)}</td></tr>');
  }
  b.write('</tbody></table></div></section>');

  // card and setup
  b.write('<section class="card"><h2>Card and setup</h2><table class="kv">');
  b.write(_kv('Reader', r.reader));
  b.write(_kv('Applet AID', r.appletAid, mono: true));
  b.write(_kv('iPhone app AID list', r.aidList, mono: true));
  if (r.atr != null) b.write(_kv('ATR', r.atr!, mono: true));
  if (r.cardType != null) b.write(_kv('Card type', r.cardType!));
  if (r.uid != null) b.write(_kv('NFC UID', r.uid!, mono: true));
  if (r.historical != null) b.write(_kv('Historical bytes', r.historical!, mono: true));
  if (r.cardId != null) b.write(_kv('Card ID (GET UID 80 08)', r.cardId!, mono: true));
  b.write('</table></section>');

  // per phone: the check steps and the full test rows
  for (final p in s.platforms) {
    final phone = _e(p.platform.short);
    b.write('<section class="card"><h2>$phone</h2>');
    if (p.checkVerdict.isNotEmpty) {
      b.write('<p class="line ${p.checkYes == true ? (p.checkWarnings > 0 ? 'warn' : 'ok') : 'fail'}">'
          '${_e(p.checkVerdict)}</p>');
    }
    if (p.read != null) {
      final read = p.read!;
      b.write('<p class="line ${read.ok ? (read.warnings.isEmpty ? 'ok' : 'warn') : 'fail'}">${_e(read.message)}</p>');
      if (read.warnings.isNotEmpty) {
        b.write('<ul>');
        for (final w in read.warnings) {
          b.write('<li>${_e(w)}</li>');
        }
        b.write('</ul>');
      }
    }
    if (p.checkRows.isNotEmpty) {
      b.write('<h3>What the $phone does, step by step</h3><div class="scroll"><table>'
          '<thead><tr><th>Step</th><th>Result</th><th>Details</th></tr></thead><tbody>');
      for (final row in p.checkRows) {
        b.write('<tr class="${row.result}"><td><b>${_e(row.step)}</b></td><td>${_pill(row.result)}</td>'
            '<td>${_e(row.details)}</td></tr>');
      }
      b.write('</tbody></table></div>');
    }
    if (p.testRows.isNotEmpty) {
      b.write('<p class="muted">${_e(p.testSummary)}</p>');
      for (final group in CheckGroup.values) {
        final rows = p.testRows.where((x) => x.group == group).toList();
        if (rows.isEmpty) continue;
        b.write('<h3>${_e(_groupName(group))}</h3><div class="scroll"><table><thead><tr>'
            '<th>ID</th><th>Result</th><th>Check</th><th>APDU</th><th>Expected</th><th>Got</th><th>Type</th>'
            '</tr></thead><tbody>');
        for (final x in rows) {
          b.write('<tr class="${x.result}"><td><b>${_e(x.id)}</b></td><td>${_pill(x.result)}</td><td>${_e(x.check)}</td>'
              '<td class="mono">${_e(x.apdu)}</td><td class="mono">${_e(x.expected)}</td><td class="mono">${_e(x.got)}</td>'
              '<td>${x.answer == null ? '' : '<span class="tag" title="${_e(x.answer!.text)}">${_e(x.answer!.tag)}</span>'}</td></tr>');
        }
        b.write('</tbody></table></div>');
      }
    }
    b.write('</section>');
  }

  if (r.dataReports.isNotEmpty) {
    b.write('<section class="card"><h2>The card data</h2>'
        '<p class="muted">Every byte that was read is in its own report, so this page stays small:</p><ul>');
    for (final path in r.dataReports) {
      b.write('<li class="mono">${_e(path)}</li>');
    }
    b.write('</ul></section>');
  }

  if (r.log.isNotEmpty) {
    b.write('<section class="card"><details><summary>APDU log (${r.log.length} lines)</summary><pre>');
    for (final line in r.log) {
      b.write('${_e(line)}\n');
    }
    b.write('</pre></details></section>');
  }

  b.write('</main><footer class="wrap">Made by NFC Card Tester on ${_e(when)}. '
      'A PC reader is not a phone: the antenna, the chip timing and OS bugs still need a real phone app.</footer></body></html>');
  return b.toString();
}

String _groupName(CheckGroup g) => switch (g) {
      CheckGroup.steps => 'Phone steps',
      CheckGroup.forty => 'Card checks (card_test.ps1)',
      CheckGroup.extra => 'Extra checks',
    };

String _tile(String label, String value, String text, String cls) =>
    '<div class="tile $cls"><div class="label">${_e(label)}</div><div class="value">${_e(value)}</div>'
    '<div class="text">${_e(text)}</div></div>';

String _kv(String k, String v, {bool mono = false}) =>
    '<tr><th>${_e(k)}</th><td${mono ? ' class="mono"' : ''}>${_e(v)}</td></tr>';

String _pill(String result) => '<span class="pill p-${_e(result)}">${_e(result)}</span>';

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
.wrap{max-width:1200px;margin:0 auto;padding:0 20px}
header{background:linear-gradient(120deg,#4f6bed,#22d3ee);color:#fff;padding:26px 0 30px;margin-bottom:22px}
header h1{margin:6px 0 2px;font-size:31px}header p{margin:0;opacity:.9}.brand{font-weight:700;opacity:.9}
.logo{display:inline-block;margin-right:6px}
.verdict{border-radius:18px;padding:20px 24px;margin-bottom:18px;border:1px solid var(--line)}
.verdict .big{font-size:30px;font-weight:800;letter-spacing:.01em}
.verdict p{margin:6px 0 0;max-width:80ch}
.verdict p.sim{font-weight:800;color:var(--warn);background:rgba(251,191,36,.14);border:1px solid rgba(251,191,36,.5);border-radius:10px;padding:8px 12px}
.verdict.ok{background:rgba(34,197,94,.12);border-color:rgba(34,197,94,.45)}.verdict.ok .big{color:var(--ok)}
.verdict.warn{background:rgba(251,191,36,.12);border-color:rgba(251,191,36,.45)}.verdict.warn .big{color:var(--warn)}
.verdict.fail{background:rgba(248,113,113,.12);border-color:rgba(248,113,113,.45)}.verdict.fail .big{color:var(--fail)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:14px;margin-bottom:18px}
.tile{background:var(--panel);border:1px solid var(--line);border-left:6px solid var(--info);border-radius:16px;padding:13px 16px}
.tile .label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.tile .value{font-size:25px;font-weight:800;margin:2px 0}
.tile .text{color:var(--muted);font-size:12.5px}
.tile.ok{border-left-color:var(--ok)}.tile.ok .value{color:var(--ok)}
.tile.warn{border-left-color:var(--warn)}.tile.warn .value{color:var(--warn)}
.tile.fail{border-left-color:var(--fail)}.tile.fail .value{color:var(--fail)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:18px 20px;margin-bottom:18px}
.card h2{margin:0 0 12px;font-size:20px}
.card h3{margin:18px 0 8px;font-size:14px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
.line{font-weight:700;padding:10px 14px;border-radius:12px;margin:0 0 10px}
.line.ok{background:rgba(34,197,94,.12);color:var(--ok)}
.line.warn{background:rgba(251,191,36,.12);color:var(--warn)}
.line.fail{background:rgba(248,113,113,.12);color:var(--fail)}
.muted{color:var(--muted)}
.scroll{overflow-x:auto}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;vertical-align:top;padding:7px 9px;border-bottom:1px solid var(--line)}
thead th{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
table.kv th{width:240px;color:var(--muted);font-weight:600}
.mono,pre{font-family:Consolas,"Cascadia Mono",monospace;font-size:12.5px}
td.mono{word-break:break-all}
tr.FAIL td{background:rgba(248,113,113,.07)}
tr.WARN td{background:rgba(251,191,36,.06)}
.pill{display:inline-block;padding:1px 10px;border-radius:999px;font-weight:700;font-size:11.5px;white-space:nowrap}
.p-PASS,.p-OK{background:rgba(34,197,94,.16);color:var(--ok)}
.p-FAIL{background:rgba(248,113,113,.16);color:var(--fail)}
.p-WARN,.p-NOTE{background:rgba(251,191,36,.18);color:var(--warn)}
.p-BLOCKED{background:rgba(167,139,250,.16);color:var(--blocked)}
.p-INFO{background:rgba(148,163,184,.16);color:var(--info)}
.tag{display:inline-block;padding:0 7px;border-radius:6px;font-weight:700;font-size:11px;white-space:nowrap;border:1px solid var(--muted);color:var(--muted)}
ul{margin:6px 0 0;padding-left:20px}li{margin-bottom:4px}
details summary{cursor:pointer;font-weight:700}
pre{white-space:pre-wrap;margin:10px 0 0}
footer{color:var(--muted);font-size:12px;padding:6px 20px 28px;max-width:90ch}
''';
