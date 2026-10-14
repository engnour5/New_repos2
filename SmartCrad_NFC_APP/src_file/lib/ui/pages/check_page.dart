import 'package:flutter/material.dart';

import '../../core/phone_check.dart';
import '../../core/platform.dart';
import '../../state/app_state.dart';
import '../phone.dart';
import '../theme.dart';
import '../widgets.dart';

class CheckPage extends StatelessWidget {
  const CheckPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final p = state.platform;
    final running = state.busy && state.busyTitle == '${p.short} check';
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 340,
        child: Panel(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: Column(children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.contain,
                child: PhoneMockup(
                  phase: state.phase,
                  title: state.phoneTitle,
                  detail: state.phoneDetail,
                  busy: state.busy,
                  platform: p,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: Tooltip(
                message: state.connected ? 'Read-only: nothing is written to the card' : 'Click Connect at the top first',
                child: FilledButton.icon(
                  onPressed: state.canRun ? state.runCheck : null,
                  icon: running
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4))
                      : Icon(p == PhonePlatform.iphone ? Icons.phone_iphone_rounded : Icons.smartphone_rounded),
                  label: Text('Check this card like an ${p.short}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: state.checkRows.isEmpty && state.testRows.isEmpty || state.busy ? null : state.saveHtmlReport,
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('HTML report'),
              ),
            ),
            const SizedBox(height: 6),
            Text(state.connected ? 'Read-only: nothing is written to the card.' : 'Connect first, at the top.',
                style: TextStyle(color: state.connected ? subtleText(context) : warnColor, fontSize: 12)),
          ]),
        ),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _VerdictBanner(state: state, running: running),
          const SizedBox(height: 14),
          Expanded(
            child: Panel(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                PanelHeader(
                  icon: Icons.timeline_rounded,
                  title: 'What the ${p.phone} does, step by step',
                  trailing: Text('${state.checkRows.length} steps', style: TextStyle(color: subtleText(context), fontSize: 12)),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: state.checkRows.isEmpty
                      ? EmptyState(
                          icon: Icons.phonelink_ring_rounded,
                          title: state.connected ? 'Ready' : 'Connect first',
                          text: state.connected
                              ? 'Click "Check this card like an ${p.short}". The tool taps the card the way an ${p.phone} does, '
                                  'follows its rules, and tells you if an ${p.app} can use it.'
                              : 'Put the card on the reader, choose the reader at the top and click Connect.',
                        )
                      : ListView.builder(
                          itemCount: state.checkRows.length,
                          itemBuilder: (context, i) => FadeSlideIn(child: _StepTile(row: state.checkRows[i], last: i == state.checkRows.length - 1)),
                        ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.state, required this.running});

  final AppState state;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final yes = state.verdictYes;
    final p = state.checkPlatform ?? state.platform;
    late final Color color;
    late final IconData icon;
    late final String title;
    late final String text;
    if (running) {
      color = nfcColor;
      icon = Icons.sensors_rounded;
      title = 'Checking...';
      text = 'Tapping the card and following the ${state.platform.short} rules.';
    } else if (yes == null) {
      color = Theme.of(context).colorScheme.primary;
      icon = Icons.help_outline_rounded;
      final error = state.checkError; // this phone's last check, never the other phone's
      title = error != null ? 'Stopped' : 'Will this card work with an ${state.platform.phone}?';
      text = error ??
          (state.platform == PhonePlatform.iphone
              ? 'One click answers it. It uses the AID list at the top, like the Info.plist of an iPhone app.'
              : 'One click answers it. An Android app needs no AID list: any app with the NFC permission can use the card.');
    } else if (yes) {
      color = state.verdictWarnings > 0 ? warnColor : okColor;
      icon = Icons.verified_rounded;
      title = '${state.verdictWarnings > 0 ? 'YES, with ${state.verdictWarnings} warning${state.verdictWarnings == 1 ? '' : 's'}' : 'YES'}'
          '  ·  ${p.short}';
      text = state.verdict;
    } else {
      color = failColor;
      icon = Icons.cancel_rounded;
      title = 'NO  ·  ${p.short}';
      text = state.verdict;
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.24), color.withValues(alpha: 0.06)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
          child: Icon(icon, key: ValueKey(icon), size: 46, color: color),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(title, key: ValueKey(title), style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: color)),
            ),
            const SizedBox(height: 4),
            Text(text, style: TextStyle(fontSize: 13.5, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85))),
          ]),
        ),
      ]),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.row, required this.last});

  final StepRow row;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final s = statusStyle(row.result);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 34,
          child: Column(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: s.color.withValues(alpha: 0.15), shape: BoxShape.circle),
              child: Icon(s.icon, size: 18, color: s.color),
            ),
            if (!last) Expanded(child: Container(width: 2, color: borderColor(context))),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14, top: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(row.step, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5))),
                StatusChip(row.result, dense: true),
              ]),
              const SizedBox(height: 4),
              SelectableText(row.details, style: TextStyle(fontSize: 12.5, color: subtleText(context), height: 1.4)),
            ]),
          ),
        ),
      ]),
    );
  }
}
