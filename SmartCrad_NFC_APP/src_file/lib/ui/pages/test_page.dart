import 'package:flutter/material.dart';

import '../../core/card_test.dart';
import '../../core/error_map.dart';
import '../../core/platform.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

enum _Filter { all, problems, forty, extra }

class TestPage extends StatefulWidget {
  const TestPage({super.key, required this.state});

  final AppState state;

  @override
  State<TestPage> createState() => _TestPageState();
}

class _TestPageState extends State<TestPage> {
  _Filter _filter = _Filter.all;

  Future<void> _run() async {
    final state = widget.state;
    if (!state.usingSimulator) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.edit_note_rounded),
          title: const Text('Run the card unit test?'),
          content: const Text('The test writes test bytes inside 0000-003F, 0100-01FE and 7FC0-7FFF. '
              'It saves those areas first and writes them back at the end. If they cannot be saved, nothing is written.\n\n'
              'Every check runs, even when the card answers wrongly.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Run it')),
          ],
        ),
      );
      if (go != true) return;
    }
    await state.runTest();
  }

  bool _keep(CheckRow r) {
    switch (_filter) {
      case _Filter.all:
        return true;
      case _Filter.problems:
        return r.result != 'PASS';
      case _Filter.forty:
        return r.group == CheckGroup.forty;
      case _Filter.extra:
        return r.group == CheckGroup.extra;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final rows = state.testRows;
    List<CheckRow> of(CheckGroup g) => rows.where((r) => r.group == g).toList();
    final forty = of(CheckGroup.forty), extra = of(CheckGroup.extra);
    int count(List<CheckRow> list, String result) => list.where((r) => r.result == result).length;
    final pass40 = count(forty, 'PASS');
    final failAll = count(rows, 'FAIL');
    final progress = state.testRunning ? rows.length / CardTest.expectedRows : (rows.isEmpty ? 0.0 : 1.0);
    final done = !state.testRunning && rows.isNotEmpty;
    final ringColors = failAll > 0 ? const [failColor, Color(0xFFF97316)] : (done ? const [okColor, Color(0xFF14B8A6)] : const [seed, nfcColor]);
    final p = state.testPlatform ?? state.platform;

    // the visible rows, with a heading row before each group
    final shown = rows.where(_keep).toList();
    final items = <Object>[];
    CheckGroup? last;
    for (final r in shown) {
      if (r.group != last) {
        items.add(r.group);
        last = r.group;
      }
      items.add(r);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        padding: const EdgeInsets.all(18),
        child: Row(children: [
          ProgressRing(
            value: progress,
            colors: ringColors,
            size: 122,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(rows.isEmpty ? '--' : '$pass40/${forty.isEmpty ? 40 : forty.length}',
                  style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
              Text(state.testRunning ? 'running' : 'card checks', style: TextStyle(fontSize: 12, color: subtleText(context))),
            ]),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Card Unit Test, run as an ${p.app}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('The card unit test: 29 checks + 14 extra checks and the card size. Tap 1 runs C01-C31 and X02-X12, '
                  'then writes the saved bytes back; tap 2 runs C32-C36 and X15. Every check runs, even after a failure; '
                  'one that cannot reach the card is a FAIL that says why.',
                  style: TextStyle(color: subtleText(context), fontSize: 12.5)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                CountChip(count: count(rows, 'PASS'), label: 'PASS', color: okColor, icon: Icons.check_circle_rounded),
                CountChip(count: failAll, label: 'FAIL', color: failColor, icon: Icons.cancel_rounded),
                CountChip(count: count(rows, 'BLOCKED'), label: 'BLOCKED BY iOS', color: blockedColor, icon: Icons.block_rounded),
                CountChip(count: count(rows, 'NOTE'), label: 'NOTE', color: warnColor, icon: Icons.sticky_note_2_outlined),
                CountChip(count: count(extra, 'PASS'), label: 'EXTRA PASS', color: nfcColor, icon: Icons.add_task_rounded),
                Tooltip(
                  message: "Answers that did not pass and are what the ORIGINAL applet (the old .cap) sends, from the error map",
                  child: CountChip(
                      count: rows.where((r) => r.result != 'PASS' && r.answer?.kind == AnswerKind.originalApplet).length,
                      label: 'OLD APPLET ANSWERS',
                      color: warnColor,
                      icon: Icons.history_rounded),
                ),
              ]),
              if (state.testSummary.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(state.testSummary,
                    style: TextStyle(fontSize: 12.5, color: failAll == 0 ? okColor : failColor, fontWeight: FontWeight.w600)),
              ],
            ]),
          ),
          const SizedBox(width: 14),
          _SizeTile(size: state.cardSize, running: state.testRunning, stop: state.cardSizeStop),
          const SizedBox(width: 14),
          SizedBox(
            width: 200,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                height: 46,
                child: Tooltip(
                  message: state.connected ? '' : 'Click Connect at the top first',
                  child: FilledButton.icon(
                    onPressed: state.canRun ? _run : null,
                    icon: state.testRunning
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4))
                        : const Icon(Icons.play_arrow_rounded),
                    label: const Text('Run Card Unit Test', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: (rows.isEmpty && state.checkRows.isEmpty) || state.busy ? null : state.saveHtmlReport,
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('HTML report'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: rows.isEmpty || state.busy ? null : state.saveCsv,
                icon: const Icon(Icons.table_view_outlined, size: 18),
                label: const Text('Save CSV'),
              ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      Expanded(
        child: Panel(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PanelHeader(
              icon: Icons.fact_check_outlined,
              title: 'Results',
              trailing: SegmentedButton<_Filter>(
                segments: const [
                  ButtonSegment(value: _Filter.all, label: Text('All')),
                  ButtonSegment(value: _Filter.problems, label: Text('Not PASS')),
                  ButtonSegment(value: _Filter.forty, label: Text('Card checks')),
                  ButtonSegment(value: _Filter.extra, label: Text('Extra')),
                ],
                selected: {_filter},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _filter = s.first),
              ),
            ),
            const SizedBox(height: 10),
            const _HeaderRow(),
            const Divider(height: 1),
            Expanded(
              child: rows.isEmpty
                  ? EmptyState(
                      icon: Icons.fact_check_outlined,
                      title: state.connected ? 'No results yet' : 'Connect first',
                      text: state.connected
                          ? 'Click "Run Card Unit Test". The card checks, the extra checks and the card size run the way an ${p.app} would run them.'
                          : 'Put the card on the reader, choose the reader at the top and click Connect.',
                    )
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final item = items[i];
                        if (item is CheckGroup) return _GroupHeader(group: item, platform: p);
                        return FadeSlideIn(offset: 8, child: _ResultRow(row: item as CheckRow, odd: i.isOdd));
                      },
                    ),
            ),
          ]),
        ),
      ),
    ]);
  }
}

class _SizeTile extends StatelessWidget {
  const _SizeTile({required this.size, required this.running, required this.stop});

  final int? size;
  final bool running;
  final String stop;

  @override
  Widget build(BuildContext context) {
    final known = size != null;
    final ok = size == CardTest.fullSize;
    final color = !known ? subtleText(context) : (ok ? okColor : failColor);
    return Tooltip(
      message: known
          ? 'Read 256 bytes at a time until the card stopped ($stop). Only ${CardTest.fullSize} bytes passes.'
          : 'The card unit test reads the whole card to find its size. Only ${CardTest.fullSize} bytes passes.',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        width: 170,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(Icons.sd_card_outlined, size: 16, color: color),
            const SizedBox(width: 6),
            Text('CARD SIZE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.6)),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(known ? '$size' : (running ? '...' : '--'),
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: known ? color : null)),
          ),
          Text(known ? (ok ? 'bytes · PASS (32 KB)' : 'bytes · FAIL (needs 32768)') : 'bytes', style: TextStyle(fontSize: 12, color: color)),
        ]),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group, required this.platform});

  final CheckGroup group;
  final PhonePlatform platform;

  @override
  Widget build(BuildContext context) {
    final (title, icon) = switch (group) {
      CheckGroup.steps => ('${platform.short} steps: taps and session time', Icons.nfc_rounded),
      CheckGroup.forty => ('Card checks (card_test.ps1)', Icons.checklist_rounded),
      CheckGroup.extra => ('Extra checks: more error-map cases, the largest command, the card ID and the card size', Icons.add_task_rounded),
    };
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6, left: 4),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: color, fontSize: 13))),
      ]),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: subtleText(context));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(children: [
        SizedBox(width: 48, child: Text('ID', style: style)),
        SizedBox(width: 112, child: Text('RESULT', style: style)),
        Expanded(flex: 5, child: Text('CHECK', style: style)),
        Expanded(flex: 5, child: Text('APDU', style: style)),
        Expanded(flex: 4, child: Text('EXPECTED', style: style)),
        Expanded(flex: 5, child: Text('GOT', style: style)),
        SizedBox(
          width: 104,
          child: Tooltip(
            message: 'The type of the answer, from the error map: a check of the applet (READ 2 ...), '
                "the ORIGINAL applet's answer (OLD F8 ...), DATA (right status word, other data) or UNEXPECTED",
            child: Text('TYPE', style: style),
          ),
        ),
        SizedBox(width: 60, child: Text('MS', style: style, textAlign: TextAlign.right)),
      ]),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.row, required this.odd});

  final CheckRow row;
  final bool odd;

  @override
  Widget build(BuildContext context) {
    final step = row.group == CheckGroup.steps;
    Widget cell(String text, int flex, {TextStyle? style}) => Expanded(
          flex: flex,
          child: Tooltip(
            message: text,
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style ?? const TextStyle(fontSize: 13)),
          ),
        );
    return Container(
      color: odd ? (isDark(context) ? Colors.white.withValues(alpha: 0.025) : const Color(0xFFF7F8FC)) : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Row(children: [
        SizedBox(
          width: 48,
          child: Text(row.id,
              style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 13, color: step ? nfcColor : (row.group == CheckGroup.extra ? blockedColor : null))),
        ),
        SizedBox(width: 112, child: Align(alignment: Alignment.centerLeft, child: StatusChip(row.result, dense: true))),
        cell(row.check, 5, style: TextStyle(fontSize: 13, fontStyle: step ? FontStyle.italic : null)),
        cell(row.apdu, 5, style: mono(size: 12.5)),
        cell(row.expected, 4, style: mono(size: 12.5, color: subtleText(context))),
        cell(row.got, 5, style: mono(size: 12.5)),
        SizedBox(
          width: 104,
          child: Align(alignment: Alignment.centerLeft, child: row.answer == null ? null : AnswerChip(row.answer!)),
        ),
        SizedBox(
          width: 60,
          child: Text(row.ms > 0 ? row.ms.toStringAsFixed(1) : '', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: subtleText(context))),
        ),
      ]),
    );
  }
}
