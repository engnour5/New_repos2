import 'card_test.dart';
import 'html_theme.dart';
import 'phone_check.dart';

/// Everything the HTML report shows. AppState fills it from the last runs.
class ReportInput {
  ReportInput({
    required this.generatedAt,
    required this.reader,
    required this.platform,
    required this.aidList,
    this.atr,
    this.cardType,
    this.uid,
    this.historical,
    this.cardId,
    this.checkPlatform,
    this.checkTime,
    this.checkVerdict,
    this.checkYes,
    this.checkRows = const [],
    this.testPlatform,
    this.testTime,
    this.testSummary,
    this.testRows = const [],
    this.cardSize,
    this.cardSizeStop,
    this.log = const [],
  });

  final DateTime generatedAt;
  final String reader;
  final String platform;
  final String aidList;
  final String? atr;
  final String? cardType;
  final String? uid;
  final String? historical;
  final String? cardId;
  final String? checkPlatform;
  final DateTime? checkTime;
  final String? checkVerdict;
  final bool? checkYes;
  final List<StepRow> checkRows;
  final String? testPlatform;
  final DateTime? testTime;
  final String? testSummary;
  final List<CheckRow> testRows;
  final int? cardSize;
  final String? cardSizeStop;
  final List<String> log;
}

/// Builds a self-contained HTML report (no external files), readable on screen and on paper.
String buildHtmlReport(ReportInput r) {
  final b = StringBuffer();
  final when = _date(r.generatedAt);
  final forty = r.testRows.where((x) => x.group == CheckGroup.forty).toList();
  final extra = r.testRows.where((x) => x.group == CheckGroup.extra).toList();
  final steps = r.testRows.where((x) => x.group == CheckGroup.steps).toList();
  int n(List<CheckRow> rows, String result) => rows.where((x) => x.result == result).length;
  final testFailed = n(r.testRows, 'FAIL');

  b.write('<!doctype html><html lang="en"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>Card test report ${_e(when)}</title><style>$_css</style></head><body>');

  b.write('<header><div class="wrap"><div class="brand"><span class="logo">&#x25CE;</span> NFC Card Tester</div>'
      '<h1>Card test report</h1><p>${_e(r.platform)} rules &middot; ${_e(when)}</p></div></header><main class="wrap">');

  // summary tiles
  b.write('<section class="tiles">');
  if (r.checkVerdict != null) {
    final cls = r.checkYes == true ? (r.checkVerdict!.contains('warning') ? 'warn' : 'ok') : 'fail';
    b.write(_tile('${_e(r.checkPlatform ?? '')} check', r.checkYes == true ? 'YES' : 'NO', _e(r.checkVerdict!), cls));
  }
  if (r.testRows.isNotEmpty) {
    final passed = n(forty, 'PASS');
    b.write(_tile('Card checks (${_e(r.testPlatform ?? '')})', '$passed / ${forty.length}',
        '${n(forty, 'FAIL')} failed, ${n(forty, 'BLOCKED')} blocked by iOS, ${n(forty, 'NOTE')} notes', n(forty, 'FAIL') == 0 ? 'ok' : 'fail'));
    b.write(_tile('Extra checks', '${n(extra, 'PASS')} / ${extra.length}', '${n(extra, 'FAIL')} failed, ${n(extra, 'NOTE')} notes',
        n(extra, 'FAIL') == 0 ? 'ok' : 'fail'));
  }
  if (r.cardSize != null) {
    final ok = r.cardSize == CardTest.fullSize;
    b.write(_tile('Card size', '${r.cardSize} bytes', ok ? 'PASS: the whole 32 KB file reads (0000-7FFF)' : 'FAIL: only ${CardTest.fullSize} bytes passes',
        ok ? 'ok' : 'fail'));
  }
  if (r.checkVerdict == null && r.testRows.isEmpty) {
    b.write(_tile('Nothing run yet', '-', 'Run the phone check or the card unit test, then make the report again.', 'info'));
  }
  b.write('</section>');

  // setup
  b.write('<section class="card"><h2>Card and setup</h2><table class="kv">');
  b.write(_kv('Reader', r.reader));
  b.write(_kv('Phone rules', r.platform));
  b.write(_kv('iPhone app AID list (Info.plist)', r.aidList, mono: true));
  if (r.atr != null) b.write(_kv('ATR', r.atr!, mono: true));
  if (r.cardType != null) b.write(_kv('Card type', r.cardType!));
  if (r.uid != null) b.write(_kv('NFC UID', r.uid!, mono: true));
  if (r.historical != null) b.write(_kv('Historical bytes', r.historical!, mono: true));
  if (r.cardId != null) b.write(_kv('Card ID (GET UID 80 08)', r.cardId!, mono: true));
  b.write('</table></section>');

  // phone check
  if (r.checkRows.isNotEmpty) {
    b.write('<section class="card"><h2>${_e(r.checkPlatform ?? '')} check <small>${_e(r.checkTime == null ? '' : _date(r.checkTime!))}</small></h2>');
    b.write('<p class="verdict ${r.checkYes == true ? 'ok' : 'fail'}">${_e(r.checkVerdict ?? '')}</p>');
    b.write('<div class="scroll"><table><thead><tr><th>Step</th><th>Result</th><th>Details</th></tr></thead><tbody>');
    for (final s in r.checkRows) {
      b.write('<tr><td><b>${_e(s.step)}</b></td><td>${_pill(s.result)}</td><td>${_e(s.details)}</td></tr>');
    }
    b.write('</tbody></table></div></section>');
  }

  // full test
  if (r.testRows.isNotEmpty) {
    b.write('<section class="card"><h2>Card Unit Test (${_e(r.testPlatform ?? '')}) '
        '<small>${_e(r.testTime == null ? '' : _date(r.testTime!))}</small></h2>');
    b.write('<p class="verdict ${testFailed == 0 ? 'ok' : 'fail'}">${_e(r.testSummary ?? '')}</p>');
    if (r.cardSize != null) {
      b.write('<p class="muted">Card size check: reads 256 bytes at a time from 0000 until the card stops '
          '(a 6C xx answer is read again with Le = xx). Result: <b>${r.cardSize} bytes</b>, stopped at ${_e(r.cardSizeStop ?? '')}. '
          'Only ${CardTest.fullSize} bytes passes.</p>');
    }
    b.write(_testTable('Phone steps', steps));
    b.write(_testTable('Card checks (card_test.ps1)', forty));
    b.write(_testTable('Extra checks', extra));
    b.write('</section>');
  }

  // rules
  b.write('<section class="card"><h2>Rules the tool applies</h2><div class="cols">'
      '<div><h3>iPhone (Core NFC)</h3><ul>'
      '<li>iOS finds the card by selecting the AIDs of the app\'s Info.plist list, in order. The first one that answers 90 00 lets the app have the card.</li>'
      '<li>The app can only SELECT by AID (00 A4 04 ..) the AIDs of its list. Payment AIDs are always blocked.</li>'
      '<li>iOS rebuilds each APDU from its fields; no automatic GET RESPONSE or 6C xx retry.</li>'
      '<li>A reader session ends after 60 seconds. NFC needs a paid Apple Developer account.</li></ul></div>'
      '<div><h3>Android (IsoDep)</h3><ul>'
      '<li>Android finds any ISO-DEP card without an AID. By default it first checks for NDEF data (SELECT D2 76 00 00 85 01 01).</li>'
      '<li>IsoDep.transceive() sends the bytes exactly as given; no SELECT check and no blocked AIDs.</li>'
      '<li>No session limit; each command has a timeout. Many phones send at most 261 bytes per command.</li>'
      '<li>Any app with the NFC permission works; no developer account is needed.</li></ul></div></div>'
      '<p class="muted">A PC reader is not a phone: the antenna, the NFC chip timing and OS bugs cannot be tested here. '
      'A real phone app is still the final proof.</p></section>');

  // log
  if (r.log.isNotEmpty) {
    b.write('<section class="card"><details><summary>APDU log (${r.log.length} lines)</summary><pre>');
    for (final line in r.log) {
      b.write('${_e(line)}\n');
    }
    b.write('</pre></details></section>');
  }

  b.write('</main><footer class="wrap">Made by NFC Card Tester on ${_e(when)}.</footer></body></html>');
  return b.toString();
}

String _testTable(String title, List<CheckRow> rows) {
  if (rows.isEmpty) return '';
  final b = StringBuffer('<h3>${_e(title)}</h3><div class="scroll"><table><thead><tr>'
      '<th>ID</th><th>Result</th><th>Check</th><th>APDU</th><th>Expected</th><th>Got</th><th>Type (error map)</th>'
      '<th class="num">ms</th></tr></thead><tbody>');
  for (final x in rows) {
    b.write('<tr class="${x.result}"><td><b>${_e(x.id)}</b></td><td>${_pill(x.result)}</td><td>${_e(x.check)}</td>'
        '<td class="mono">${_e(x.apdu)}</td><td class="mono">${_e(x.expected)}</td><td class="mono">${_e(x.got)}</td>'
        '<td>${_typeCell(x)}</td><td class="num">${x.ms > 0 ? x.ms.toStringAsFixed(1) : ''}</td></tr>');
  }
  b.write('</tbody></table></div>');
  return b.toString();
}

/// The type of the answer from the error map; the explanation is shown for the rows that did not pass.
String _typeCell(CheckRow x) {
  final a = x.answer;
  if (a == null) return '';
  final details = x.result == 'PASS' ? '' : '<div class="why">${_e(a.text)}</div>';
  return '<span class="tag t-${a.kind.name}" title="${_e(a.text)}">${_e(a.tag)}</span>$details';
}

String _tile(String label, String value, String text, String cls) =>
    '<div class="tile $cls"><div class="label">$label</div><div class="value">$value</div><div class="text">$text</div></div>';

String _kv(String k, String v, {bool mono = false}) => '<tr><th>${_e(k)}</th><td${mono ? ' class="mono"' : ''}>${_e(v)}</td></tr>';

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
.wrap{max-width:1180px;margin:0 auto;padding:0 20px}
header{background:linear-gradient(120deg,#4f6bed,#22d3ee);color:#fff;padding:26px 0 30px;margin-bottom:22px}
header h1{margin:6px 0 2px;font-size:30px}
header p{margin:0;opacity:.9}
.brand{font-weight:700;opacity:.9}
.logo{display:inline-block;margin-right:6px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px;margin-bottom:18px}
.tile{background:var(--panel);border:1px solid var(--line);border-left:6px solid var(--info);border-radius:16px;padding:14px 16px}
.tile .label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.tile .value{font-size:26px;font-weight:800;margin:2px 0}
.tile .text{color:var(--muted);font-size:13px}
.tile.ok{border-left-color:var(--ok)}.tile.ok .value{color:var(--ok)}
.tile.fail{border-left-color:var(--fail)}.tile.fail .value{color:var(--fail)}
.tile.warn{border-left-color:var(--warn)}.tile.warn .value{color:var(--warn)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:18px 20px;margin-bottom:18px}
.card h2{margin:0 0 12px;font-size:19px}
.card h2 small{color:var(--muted);font-weight:400;font-size:13px;margin-left:8px}
.card h3{margin:18px 0 8px;font-size:15px}
.verdict{font-weight:700;padding:10px 14px;border-radius:12px;margin:0 0 12px}
.verdict.ok{background:rgba(22,163,74,.12);color:var(--ok)}
.verdict.fail{background:rgba(220,38,38,.12);color:var(--fail)}
.muted{color:var(--muted)}
.scroll{overflow-x:auto}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;vertical-align:top;padding:7px 9px;border-bottom:1px solid var(--line)}
thead th{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
table.kv th{width:240px;color:var(--muted);font-weight:600}
.mono,pre{font-family:Consolas,"Cascadia Mono",monospace;font-size:12.5px}
td.mono{word-break:break-all}
.num{text-align:right;white-space:nowrap}
tr.FAIL td{background:rgba(220,38,38,.07)}
.pill{display:inline-block;padding:1px 10px;border-radius:999px;font-weight:700;font-size:11.5px;letter-spacing:.03em;white-space:nowrap}
.p-PASS,.p-OK{background:rgba(22,163,74,.14);color:var(--ok)}
.p-FAIL{background:rgba(220,38,38,.14);color:var(--fail)}
.p-WARN,.p-NOTE{background:rgba(217,119,6,.15);color:var(--warn)}
.p-BLOCKED{background:rgba(124,58,237,.14);color:var(--blocked)}
.p-INFO{background:rgba(71,85,105,.14);color:var(--info)}
.tag{display:inline-block;padding:0 7px;border-radius:6px;font-weight:700;font-size:11px;white-space:nowrap;border:1px solid currentColor}
.t-success{color:var(--ok)}.t-appletError{color:#4f6bed}.t-originalApplet{color:var(--warn)}.t-wrongData,.t-unexpected{color:var(--fail)}
.why{color:var(--muted);font-size:12px;margin-top:3px;min-width:260px}
.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:18px}
ul{margin:6px 0 0;padding-left:20px}li{margin-bottom:4px}
details summary{cursor:pointer;font-weight:700}
pre{white-space:pre-wrap;margin:10px 0 0}
footer{color:var(--muted);font-size:12px;padding:6px 20px 26px}
@media print{header,.tile,.pill,.verdict{-webkit-print-color-adjust:exact;print-color-adjust:exact}details{display:none}}
''';
