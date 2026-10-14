import 'package:flutter/material.dart';

import '../core/log.dart';
import '../state/app_state.dart';
import 'log_line.dart';
import 'theme.dart';

/// The live log along the bottom of every page: what was sent and what the card answered, as it happens.
///
/// It opens by itself while a run is going, so you can watch any test without leaving its screen, and closes again
/// when the run ends unless you pin it. Collapsed, it still shows the last line.
class LogDock extends StatefulWidget {
  const LogDock({super.key, required this.state});

  final AppState state;

  /// How much of the log the strip keeps on screen. The Log page has all of it.
  static const shown = 300;

  @override
  State<LogDock> createState() => _LogDockState();
}

class _LogDockState extends State<LogDock> {
  final _scroll = ScrollController();
  int _seen = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final all = state.logEntries;
    final open = state.logDockOpen;
    final entries = all.length <= LogDock.shown ? all : all.sublist(all.length - LogDock.shown);

    // follow the newest line while it is open
    if (open && all.length != _seen) {
      _seen = all.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }

    final last = all.isEmpty ? null : all.last;
    return Container(
      decoration: BoxDecoration(
        color: panelColor(context).withValues(alpha: 0.9),
        border: Border(top: BorderSide(color: borderColor(context))),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: state.toggleLogDock,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(children: [
              Icon(Icons.terminal_rounded, size: 16, color: state.busy ? okColor : subtleText(context)),
              const SizedBox(width: 8),
              Text('Live log', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: subtleText(context))),
              const SizedBox(width: 8),
              Text('${all.length}', style: TextStyle(fontSize: 11.5, color: subtleText(context))),
              const SizedBox(width: 12),
              // closed, the newest line is still worth seeing
              if (!open)
                Expanded(
                  child: last == null
                      ? Text('Nothing sent yet. It opens by itself while a test runs.',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: subtleText(context)))
                      : Text(last.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono(size: 12, color: _colorOf(context, last))),
                )
              else
                const Spacer(),
              if (state.busy) ...[
                const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.8)),
                const SizedBox(width: 10),
              ],
              IconButton(
                tooltip: 'Clear the log',
                visualDensity: VisualDensity.compact,
                onPressed: all.isEmpty ? null : state.clearLog,
                icon: const Icon(Icons.delete_sweep_outlined, size: 17),
              ),
              IconButton(
                tooltip: open ? 'Hide the live log' : 'Show the live log',
                visualDensity: VisualDensity.compact,
                onPressed: state.toggleLogDock,
                icon: Icon(open ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded, size: 20),
              ),
            ]),
          ),
        ),
        if (open)
          SizedBox(
            height: 150,
            child: entries.isEmpty
                ? Center(
                    child: Text('Nothing sent yet. Every command and its answer appears here while a test runs.',
                        style: TextStyle(fontSize: 12.5, color: subtleText(context))),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
                    itemCount: entries.length,
                    itemBuilder: (context, i) => LogLine(entry: entries[i], dense: true),
                  ),
          ),
      ]),
    );
  }

  Color _colorOf(BuildContext context, LogEntry e) => switch (e.kind) {
        LogKind.received => e.sw == 0x9000 ? okColor : failColor,
        LogKind.warn => warnColor,
        LogKind.blocked => blockedColor,
        LogKind.section => Theme.of(context).colorScheme.primary,
        _ => subtleText(context),
      };
}
