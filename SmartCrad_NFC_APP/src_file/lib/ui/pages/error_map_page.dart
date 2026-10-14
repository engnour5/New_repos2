import 'package:flutter/material.dart';

import '../../core/error_map.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

/// The applet's error map: every status word, the check that sends it, what the meter should do, and the answer of the
/// ORIGINAL applet. The tool uses the same map to give every answer a type (console, log, full test, reports).
class ErrorMapPage extends StatelessWidget {
  const ErrorMapPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListView(children: [
      _section(
        context,
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const PanelHeader(icon: Icons.rule_rounded, title: 'electrical_electrometer error map'),
          const SizedBox(height: 8),
          Text(
              'Every answer the applet can send, the check that sends it, and what the meter should do. The applet runs '
              'the checks of a command from top to bottom, and the first one that fails decides the answer. The tool '
              'uses this map to give every answer a type: in the APDU console, the log, the full test (TYPE column) and '
              'the reports.',
              style: TextStyle(fontSize: 13, color: subtleText(context), height: 1.45)),
          const SizedBox(height: 10),
          const Wrap(spacing: 8, runSpacing: 8, children: [
            _Legend(AnswerKind.success, 'OK', 'the right answer'),
            _Legend(AnswerKind.appletError, 'READ 2', 'a check of the applet (section 2)'),
            _Legend(AnswerKind.originalApplet, 'OLD F8', "the ORIGINAL applet's answer (code review finding)"),
            _Legend(AnswerKind.wrongData, 'DATA', 'right status word, other data'),
            _Legend(AnswerKind.unexpected, 'UNEXPECTED', 'not in the map'),
          ]),
        ]),
      ),
      _section(
        context,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const PanelHeader(icon: Icons.tag_rounded, title: '1. Status words'),
          const SizedBox(height: 8),
          _HeaderRow(cells: const [('SW', 0, 86.0), ('ISO 7816-4 MEANING', 3, 0.0), ('THE APPLET SENDS IT WHEN', 5, 0.0), ('THE METER SHOULD', 4, 0.0)]),
          for (final (i, e) in errorMapSws.indexed) _SwRow(entry: e, odd: i.isOdd),
        ]),
      ),
      for (final command in MapCommand.values)
        _section(
          context,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PanelHeader(
              icon: Icons.terminal_rounded,
              title: '2. ${command.title}',
              trailing: Text(command.ins, style: mono(size: 12.5, color: warnColor, weight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),
            _HeaderRow(cells: const [
              ('#', 0, 44.0),
              ('FAILS WHEN', 4, 0.0),
              ('EXAMPLE', 3, 0.0),
              ('NOW', 2, 0.0),
              ('ORIGINAL APPLET', 3, 0.0),
            ]),
            for (final (i, c) in errorMapChecks.where((c) => c.command == command).indexed)
              _CheckRow(check: c, odd: i.isOdd, onTry: () => _try(c)),
          ]),
        ),
      _section(
        context,
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const PanelHeader(icon: Icons.lightbulb_outline_rounded, title: '3. Good to know'),
          const SizedBox(height: 8),
          for (final n in errorMapNotes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: warnColor, shape: BoxShape.circle)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(n, style: const TextStyle(fontSize: 13.5, height: 1.45))),
              ]),
            ),
          const SizedBox(height: 6),
          Text(
              'From review\\error_map.html (1 Oct 2026), checked by running src\\electrical_electrometer\\electrical_electrometer.java '
              '(159 lines) and the original code (review\\gas_electrometer_original.java) with the commands shown. Line numbers '
              'refer to that src; F-numbers to the code review.',
              style: TextStyle(fontSize: 12, color: subtleText(context))),
        ]),
      ),
    ]);
  }

  /// Puts the example in the APDU console. Nothing is sent until Send is clicked.
  void _try(MapCheck c) {
    state.useCommand(c.example);
    state.setPage(Pages.console);
  }

  Widget _section(BuildContext context, Widget child) =>
      Padding(padding: const EdgeInsets.only(bottom: 14), child: Panel(padding: const EdgeInsets.fromLTRB(18, 16, 18, 14), child: child));
}

class _Legend extends StatelessWidget {
  const _Legend(this.kind, this.tag, this.text);

  final AnswerKind kind;
  final String tag;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = answerColor(kind);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(tag, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      ),
      const SizedBox(width: 6),
      Text(text, style: TextStyle(fontSize: 12, color: subtleText(context))),
    ]);
  }
}

/// Column titles: (text, flex, fixed width when flex is 0).
class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.cells});

  final List<(String, int, double)> cells;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: subtleText(context), letterSpacing: 0.4);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: borderColor(context)))),
      child: Row(children: [
        for (final (text, flex, width) in cells)
          if (flex == 0) SizedBox(width: width, child: Text(text, style: style)) else Expanded(flex: flex, child: Text(text, style: style)),
      ]),
    );
  }
}

Color _swColor(String text) {
  if (text.startsWith('90 00')) return okColor;
  if (text.startsWith('6F 00')) return failColor;
  return warnColor;
}

/// "6A 82, EF kept" as a status-word chip and the rest as text.
class _Answer extends StatelessWidget {
  const _Answer(this.text, {this.finding = ''});

  final String text;
  final String finding;

  @override
  Widget build(BuildContext context) {
    final m = RegExp(r'^([0-9A-F]{2} [0-9A-Fx]{2})(.*)$').firstMatch(text);
    final sw = m?.group(1) ?? text;
    final rest = (m?.group(2) ?? '').replaceFirst(RegExp(r'^,\s*'), '').trim();
    final color = _swColor(sw);
    return Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(5)),
        child: Text(sw, style: mono(size: 12.5, color: color, weight: FontWeight.w700)),
      ),
      if (rest.isNotEmpty) Text(rest, style: TextStyle(fontSize: 12.5, color: subtleText(context))),
      if (finding.isNotEmpty) Text(finding, style: mono(size: 11.5, color: warnColor, weight: FontWeight.w700)),
    ]);
  }
}

class _SwRow extends StatelessWidget {
  const _SwRow({required this.entry, required this.odd});

  final SwEntry entry;
  final bool odd;

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.level) { SwLevel.ok => okColor, SwLevel.warn => warnColor, SwLevel.bad => failColor };
    return Container(
      color: odd ? (isDark(context) ? Colors.white.withValues(alpha: 0.025) : const Color(0xFFF7F8FC)) : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 86,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(5)),
              child: Text(entry.sw, style: mono(size: 12.5, color: color, weight: FontWeight.w700)),
            ),
          ),
        ),
        Expanded(flex: 3, child: Text(entry.iso, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        Expanded(flex: 5, child: Text(entry.when, style: const TextStyle(fontSize: 13))),
        Expanded(flex: 4, child: Text(entry.meter, style: TextStyle(fontSize: 13, color: subtleText(context)))),
      ]),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check, required this.odd, required this.onTry});

  final MapCheck check;
  final bool odd;
  final VoidCallback onTry;

  @override
  Widget build(BuildContext context) {
    final ok = check.isOk;
    return Container(
      color: odd ? (isDark(context) ? Colors.white.withValues(alpha: 0.025) : const Color(0xFFF7F8FC)) : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 44,
          child: Text(check.order, style: mono(size: 13, weight: FontWeight.w700, color: ok ? okColor : warnColor)),
        ),
        Expanded(
          flex: 4,
          child: Text.rich(TextSpan(children: [
            TextSpan(text: check.failsWhen, style: const TextStyle(fontSize: 13)),
            if (check.line > 0) TextSpan(text: '   line ${check.line}', style: mono(size: 11.5, color: subtleText(context))),
          ])),
        ),
        Expanded(
          flex: 3,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Flexible(child: SelectableText(check.example, style: mono(size: 12.5))),
            const SizedBox(width: 2),
            SizedBox(
              width: 26,
              height: 22,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 16,
                tooltip: 'Put this command in the APDU console (nothing is sent until you click Send)',
                onPressed: onTry,
                icon: const Icon(Icons.north_east_rounded),
              ),
            ),
          ]),
        ),
        Expanded(flex: 2, child: _Answer(check.now)),
        Expanded(flex: 3, child: _Answer(check.original, finding: check.finding)),
      ]),
    );
  }
}
