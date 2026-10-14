import 'package:flutter/material.dart';

import '../core/log.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// One line of the log. The Log page and the live strip at the bottom both use it, so a command never looks one way
/// in one place and another way somewhere else.
class LogLine extends StatelessWidget {
  const LogLine({super.key, required this.entry, this.dense = false});

  final LogEntry entry;

  /// The live strip is short, so it drops the timestamp column and tightens the spacing.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    Color color;
    IconData? icon;
    switch (entry.kind) {
      case LogKind.section:
        return Padding(
          padding: EdgeInsets.only(top: dense ? 6 : 12, bottom: dense ? 3 : 6),
          child: Row(children: [
            Icon(Icons.label_important_rounded, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(entry.text,
                  maxLines: dense ? 1 : null,
                  overflow: dense ? TextOverflow.ellipsis : null,
                  style: TextStyle(fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.primary, fontSize: 13)),
            ),
          ]),
        );
      case LogKind.info:
        color = onSurface.withValues(alpha: 0.8);
      case LogKind.warn:
        color = warnColor;
        icon = Icons.warning_amber_rounded;
      case LogKind.sent:
        color = onSurface;
      case LogKind.received:
        color = entry.sw == 0x9000 ? okColor : failColor;
      case LogKind.blocked:
        color = blockedColor;
        icon = Icons.block_rounded;
    }
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 0.5 : 1.5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!dense) SizedBox(width: 92, child: Text(AppState.stamp(entry.time), style: mono(size: 12, color: subtleText(context)))),
        SizedBox(width: dense ? 16 : 20, child: icon == null ? null : Icon(icon, size: 13, color: color)),
        Expanded(
          child: dense
              ? Text(entry.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 12, color: color))
              : SelectableText(entry.text, style: mono(size: 12.5, color: color)),
        ),
      ]),
    );
  }
}
