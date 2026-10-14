/// The colours every page the app writes shares, so the reports, the data dumps and the guide all look like the app.
///
/// The pages are dark, whatever the browser is set to. Printing is the one exception: a browser usually leaves
/// background colours out of a printout, which would put pale text on white paper, so the print rules swap in a light
/// palette and the page stays readable on paper.
const htmlPalette = '''
:root{
color-scheme:dark;
--bg:#0a0f1e;--panel:#121a30;--text:#e2e8f0;--muted:#94a3b8;--line:#1e2944;
--ok:#22c55e;--fail:#f87171;--warn:#fbbf24;--blocked:#a78bfa;--info:#94a3b8;
--data:#4f6bed;--accent:#8ba4ff;--zero:#1f2a44;--ff:#f59e0b;
}
@media print{:root{
color-scheme:light;
--bg:#fff;--panel:#fff;--text:#0f172a;--muted:#475569;--line:#cbd5e1;
--ok:#15803d;--fail:#b91c1c;--warn:#b45309;--blocked:#6d28d9;--info:#475569;
--data:#1d4ed8;--accent:#1d4ed8;--zero:#e2e8f0;--ff:#b45309;
}}
''';
