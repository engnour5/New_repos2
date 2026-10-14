import 'guide.dart';
import 'html_theme.dart';

/// The guide as a web page: one self-contained HTML file, readable in any browser and printable, built from the same
/// text the first page shows.
String buildGuideHtml({DateTime? generatedAt}) {
  final b = StringBuffer();
  b.write('<!doctype html><html lang="en"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>${_e(guideTitle)}</title><style>$_css</style></head><body>');

  b.write('<header><div class="wrap"><div class="brand"><span class="logo">&#x25CE;</span> NFC Card Tester</div>'
      '<h1>${_e(guideTitle)}</h1><p>${_e(guideIntro)}</p></div></header><main class="wrap">');

  // what it can do, before any of the detail
  b.write('<section class="features"><h2>What it can do</h2><div class="grid">');
  for (final f in guideFeatures) {
    b.write('<div class="feature"><b>${_e(f.name)}</b><span>${_e(f.what)}</span></div>');
  }
  b.write('</div></section>');

  // contents
  b.write('<nav class="toc"><b>On this page</b><ol>');
  for (var i = 0; i < guideSections.length; i++) {
    b.write('<li><a href="#s$i">${_e(guideSections[i].title)}</a></li>');
  }
  b.write('</ol></nav>');

  for (var i = 0; i < guideSections.length; i++) {
    final s = guideSections[i];
    b.write('<section class="card" id="s$i"><h2>${_e(s.title)}</h2><p class="intro">${_e(s.intro)}</p>');
    if (s.steps.isNotEmpty) {
      b.write('<h3>How to use it</h3><ol class="steps">');
      for (final step in s.steps) {
        b.write('<li>${_e(step)}</li>');
      }
      b.write('</ol>');
    }
    if (s.table.isNotEmpty) {
      final head = s.tableHead;
      b.write('<div class="scroll"><table>');
      if (head != null) b.write('<thead><tr><th>${_e(head.$1)}</th><th>${_e(head.$2)}</th></tr></thead>');
      b.write('<tbody>');
      for (final row in s.table) {
        b.write('<tr><td class="k">${_e(row.$1)}</td><td>${_e(row.$2)}</td></tr>');
      }
      b.write('</tbody></table></div>');
    }
    if (s.notes.isNotEmpty) {
      b.write('<h3>Worth knowing</h3><ul class="notes">');
      for (final note in s.notes) {
        b.write('<li>${_e(note)}</li>');
      }
      b.write('</ul>');
    }
    b.write('</section>');
  }

  final when = generatedAt ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  b.write('</main><footer class="wrap">NFC Card Tester &middot; guide saved on '
      '${when.year}-${two(when.month)}-${two(when.day)} ${two(when.hour)}:${two(when.minute)}</footer></body></html>');
  return b.toString();
}

String _e(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');

const _css = '''
$htmlPalette
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.6 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:900px;margin:0 auto;padding:0 20px}
header{background:linear-gradient(120deg,#4f6bed,#22d3ee);color:#fff;padding:30px 0 34px;margin-bottom:22px}
header h1{margin:8px 0 6px;font-size:30px;line-height:1.2}
header p{margin:0;opacity:.95;max-width:70ch}
.brand{font-weight:700;opacity:.9}
.logo{display:inline-block;margin-right:6px}
.features{margin-bottom:18px}
.features h2{margin:0 0 10px;font-size:18px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:12px}
.feature{background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:14px;padding:12px 14px}
.feature b{display:block;font-size:14px;margin-bottom:3px}
.feature span{color:var(--muted);font-size:12.5px;line-height:1.5}
.toc{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:14px 20px;margin-bottom:18px}
.toc ol{margin:8px 0 0;padding-left:22px;columns:2;column-gap:28px}
.toc li{margin-bottom:4px;break-inside:avoid}
.toc a{color:var(--accent);text-decoration:none}
.toc a:hover{text-decoration:underline}
.card{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:18px 22px 20px;margin-bottom:16px}
.card h2{margin:0 0 8px;font-size:20px}
.card h3{margin:16px 0 6px;font-size:14px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
.intro{margin:0;max-width:72ch}
.steps li,.notes li{margin-bottom:6px;max-width:74ch}
.steps{padding-left:22px}
.notes{padding-left:20px}
.scroll{overflow-x:auto;margin-top:12px}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;vertical-align:top;padding:8px 10px;border-bottom:1px solid var(--line)}
thead th{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
td.k{font-weight:600;white-space:nowrap}
footer{color:var(--muted);font-size:12px;padding:8px 20px 28px}
@media print{header{-webkit-print-color-adjust:exact;print-color-adjust:exact}.toc{display:none}.card{break-inside:avoid}}
''';
