import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/applet_log.dart';
import '../../core/hex.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

/// Applet log: reads the applet's OWN command logger (the passive 80 F0/F1/F2/F3 logger built into the card) and shows
/// the decoded records. This is how you see what a PHONE sent the card: arm it here, run the phone, freeze, then read -
/// the log survives the phone<->PC move because it is in the card. It is separate from the app's own APDU "Log" page.
class AppletLogPage extends StatefulWidget {
  const AppletLogPage({super.key, required this.state});

  final AppState state;

  @override
  State<AppletLogPage> createState() => _AppletLogPageState();
}

class _AppletLogPageState extends State<AppletLogPage> {
  String? _running; // 'arm' | 'freeze' | 'read'

  Future<void> _run(String key, Future<void> Function() action) async {
    if (_running != null || widget.state.busy) return;
    if (!widget.state.connected) {
      widget.state.snack('Connect to a reader first.');
      return;
    }
    setState(() => _running = key);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  void _copyAll() {
    final recs = widget.state.appletLog;
    if (recs == null || recs.isEmpty) return;
    final b = StringBuffer();
    for (var i = 0; i < recs.length; i++) {
      final r = recs[i];
      b.writeln('${(i + 1).toString().padLeft(3)}  ${r.headerHex}  ${Hex.of(r.data)}  SW ${r.swText}   | ${r.command}'
          '${r.swMeaning.isEmpty ? '' : '  -> ${r.swMeaning}'}');
    }
    Clipboard.setData(ClipboardData(text: b.toString()));
    widget.state.snack('Copied ${recs.length} log records');
  }

  @override
  Widget build(BuildContext context) {
    final recs = widget.state.appletLog;
    return ListView(padding: const EdgeInsets.only(bottom: 12), children: [
      _intro(context),
      const SizedBox(height: 12),
      _controls(context),
      if (recs != null) ...[
        const SizedBox(height: 12),
        _results(context, recs),
      ],
    ]);
  }

  Widget _intro(BuildContext context) => Panel(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(colors: [Color(0xFFEF4444), Color(0xFFF97316)])),
            child: const Icon(Icons.bug_report_rounded, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Applet log', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(
                  'Reads the applet\'s own built-in command log - every APDU the card itself received, including from a '
                  'phone. It lives inside the card (not in the 32 KB data file), so it survives the phone↔PC move and a '
                  'normal card read never shows it. Use it to capture what an Android/iPhone app actually sends.',
                  style: TextStyle(fontSize: 12.5, color: subtleText(context), height: 1.4)),
            ]),
          ),
        ]),
      );

  Widget _controls(BuildContext context) {
    final connected = widget.state.connected;
    final busy = widget.state.busy || _running != null;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('1. Arm  →  2. move the card to the phone and run its app  →  3. back here, Freeze  →  4. Read log',
            style: TextStyle(fontSize: 12.5, color: subtleText(context))),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _btn(context, 'arm', Icons.play_circle_outline_rounded, 'Arm (clear + start)', const Color(0xFF16A34A),
              () => _run('arm', widget.state.armAppletLog), busy),
          _btn(context, 'freeze', Icons.pause_circle_outline_rounded, 'Freeze', const Color(0xFFF59E0B),
              () => _run('freeze', widget.state.freezeAppletLog), busy),
          _btn(context, 'read', Icons.download_rounded, 'Read log', const Color(0xFFEF4444),
              () => _run('read', widget.state.readAppletLog), busy, filled: true),
        ]),
        if (!connected) ...[
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.info_outline_rounded, size: 15, color: warnColor),
            const SizedBox(width: 7),
            Expanded(
                child: Text('Put the card on the reader and click Connect at the top first.',
                    style: TextStyle(fontSize: 12, color: warnColor))),
          ]),
        ],
        if (widget.state.appletLogStatus != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.receipt_long_rounded, size: 15, color: subtleText(context)),
            const SizedBox(width: 7),
            Text(widget.state.appletLogStatus!, style: mono(size: 12.5, weight: FontWeight.w700)),
          ]),
        ],
      ]),
    );
  }

  Widget _btn(BuildContext context, String key, IconData icon, String label, Color color, VoidCallback onTap, bool busy,
          {bool filled = false}) =>
      SizedBox(
        height: 42,
        child: filled
            ? FilledButton.icon(
                onPressed: busy ? null : onTap,
                style: FilledButton.styleFrom(backgroundColor: color),
                icon: _running == key ? _spin() : Icon(icon, size: 18),
                label: Text(label))
            : OutlinedButton.icon(
                onPressed: busy ? null : onTap,
                style: OutlinedButton.styleFrom(foregroundColor: color, side: BorderSide(color: color.withValues(alpha: 0.5))),
                icon: _running == key ? _spin() : Icon(icon, size: 18),
                label: Text(label)),
      );

  Widget _spin() => const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2.2));

  Color _swColor(AppletLogRecord r) {
    if (r.ok) return okColor;
    if ((r.sw & 0xff00) == 0x6C00) return warnColor;
    return failColor;
  }

  Widget _results(BuildContext context, List<AppletLogRecord> recs) => Panel(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const PanelHeader(icon: Icons.format_list_numbered_rounded, title: 'Captured commands'),
            const Spacer(),
            if (recs.isNotEmpty)
              TextButton.icon(onPressed: _copyAll, icon: const Icon(Icons.copy_rounded, size: 16), label: const Text('Copy')),
          ]),
          const SizedBox(height: 6),
          if (recs.isEmpty)
            Text('The log is empty — nothing has been recorded since it was armed. Arm it, run the phone, then Read.',
                style: TextStyle(fontSize: 13, color: subtleText(context)))
          else
            for (var i = 0; i < recs.length; i++) _recordTile(context, i, recs[i]),
        ]),
      );

  Widget _recordTile(BuildContext context, int index, AppletLogRecord r) {
    final color = _swColor(r);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(width: 30, child: Text('${index + 1}', style: TextStyle(fontSize: 12, color: subtleText(context)))),
          Expanded(child: Text(r.command, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(7)),
            child: Text(r.swText, style: mono(size: 12.5, weight: FontWeight.w800, color: color)),
          ),
        ]),
        const SizedBox(height: 3),
        Padding(
          padding: const EdgeInsets.only(left: 30),
          child: Text(
              '${r.headerHex}   data ${Hex.of(r.data)}${r.swMeaning.isEmpty ? '' : '   ·   ${r.swMeaning}'}',
              style: mono(size: 11, color: subtleText(context))),
        ),
      ]),
    );
  }
}
