import 'package:flutter/material.dart';

import '../../core/production.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

/// One button that runs every test on both phones, adds the production checks, and writes one report.
class RunAllPage extends StatefulWidget {
  const RunAllPage({super.key, required this.state});

  final AppState state;

  @override
  State<RunAllPage> createState() => _RunAllPageState();
}

class _RunAllPageState extends State<RunAllPage> {
  Future<void> _run() async {
    final state = widget.state;
    if (!state.usingSimulator) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.rocket_launch_outlined, size: 40),
          title: const Text('Run every test?'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: const Text('This runs the check, the card read and the card unit test as an iPhone and then as an '
                'Android, and finishes with the production checks. It takes a minute or two.\n\n'
                'The card unit test writes inside 0000-003F, 0100-01FE and 7FC0-7FFF. Those areas are saved first and '
                'written back; if they cannot be saved, nothing is written.\n\n'
                'Leave the card on the reader until it finishes.'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Run everything')),
          ],
        ),
      );
      if (go != true) return;
    }
    await state.runAllTests();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final s = state.production;
    final running = state.runAllRunning;
    final done = AppState.runAllStages.indexOf(state.runAllStage);
    final progress = running
        ? (done < 0 ? 0.0 : done / AppState.runAllStages.length)
        : (s == null ? 0.0 : 1.0);
    final ringColors = s == null
        ? const [seed, nfcColor]
        : (s.failures > 0
            ? const [failColor, Color(0xFFF97316)]
            : (s.warnings > 0 ? const [warnColor, Color(0xFFF97316)] : const [okColor, Color(0xFF14B8A6)]));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        padding: const EdgeInsets.all(18),
        child: Row(children: [
          ProgressRing(
            value: progress,
            colors: ringColors,
            size: 124,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(s == null ? Icons.rocket_launch_outlined : (s.ready ? Icons.verified_rounded : Icons.cancel_rounded),
                  size: 30, color: s == null ? null : (s.ready ? (s.warnings > 0 ? warnColor : okColor) : failColor)),
              const SizedBox(height: 2),
              Text(running ? 'running' : (s == null ? 'ready' : (s.ready ? 'READY' : 'NOT READY')),
                  style: TextStyle(
                      fontSize: s == null || running ? 12 : 14,
                      fontWeight: FontWeight.w800,
                      color: s == null ? subtleText(context) : (s.ready ? (s.warnings > 0 ? warnColor : okColor) : failColor))),
            ]),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Run all tests', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                  'The check, the card read and the card unit test, as an iPhone and then as an Android, plus the '
                  'production checks. One report at the end says whether the card is ready.',
                  style: TextStyle(color: subtleText(context), fontSize: 12.5)),
              if (s != null && s.simulated) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: warnColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: warnColor.withValues(alpha: 0.5)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.memory_rounded, size: 17, color: warnColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(ProductionSummary.simulatorNote,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: warnColor, height: 1.35)),
                    ),
                  ]),
                ),
              ],
              if (s != null) ...[
                const SizedBox(height: 10),
                Text(s.verdict.replaceFirst('${ProductionSummary.simulatorNote} ', ''),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: s.failures > 0 ? failColor : (s.warnings > 0 ? warnColor : okColor))),
              ],
              if (running) ...[
                const SizedBox(height: 10),
                Row(children: [
                  const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2.2)),
                  const SizedBox(width: 10),
                  Text(state.runAllStage.isEmpty ? 'Starting...' : '${state.runAllStage}...',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ],
            ]),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 210,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                height: 50,
                child: Tooltip(
                  message: state.connected ? '' : 'Click Connect at the top first',
                  child: FilledButton.icon(
                    onPressed: state.canRun && !running ? _run : null,
                    icon: running
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4))
                        : const Icon(Icons.rocket_launch_rounded),
                    label: const Text('Run all tests', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: s == null || state.busy ? null : () => state.saveProductionReport(),
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('Final report'),
              ),
              if (state.productionReportPath != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Saved and opened in your browser.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: subtleText(context))),
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
              icon: Icons.checklist_rtl_rounded,
              title: 'Stages',
              trailing: s == null
                  ? null
                  : Text('${s.stages.length - s.failures - s.warnings} of ${s.stages.length} clean',
                      style: TextStyle(fontSize: 12.5, color: subtleText(context))),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: s == null
                  ? _plan(context, state)
                  : ListView.builder(
                      itemCount: s.stages.length,
                      itemBuilder: (context, i) => FadeSlideIn(offset: 8, child: _StageTile(stage: s.stages[i], odd: i.isOdd)),
                    ),
            ),
          ]),
        ),
      ),
    ]);
  }

  /// Before anything runs: what will happen, in order.
  Widget _plan(BuildContext context, AppState state) {
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
            state.connected
                ? 'Nothing has run yet. Clicking "Run all tests" does these, in this order:'
                : 'Connect first, then "Run all tests" does these, in this order:',
            style: TextStyle(color: subtleText(context), fontSize: 13)),
      ),
      for (var i = 0; i < AppState.runAllStages.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Text('${i + 1}',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.primary)),
            ),
            const SizedBox(width: 12),
            Text(AppState.runAllStages[i], style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          ]),
        ),
      const SizedBox(height: 10),
      Text(
          'The read-only runs come first on each phone and the card unit test last, so a card that is already wrong '
          'is found before anything is written to it.',
          style: TextStyle(color: subtleText(context), fontSize: 12.5, height: 1.45)),
    ]);
  }
}

class _StageTile extends StatelessWidget {
  const _StageTile({required this.stage, required this.odd});

  final StageOutcome stage;
  final bool odd;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: odd ? (isDark(context) ? Colors.white.withValues(alpha: 0.025) : const Color(0xFFF7F8FC)) : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 110, child: Align(alignment: Alignment.centerLeft, child: StatusChip(stage.result, dense: true))),
        const SizedBox(width: 8),
        SizedBox(
          width: 220,
          child: Text(stage.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Expanded(child: SelectableText(stage.detail, style: TextStyle(fontSize: 12.5, color: subtleText(context), height: 1.4))),
      ]),
    );
  }
}
