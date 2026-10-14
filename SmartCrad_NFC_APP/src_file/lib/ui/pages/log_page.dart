import 'package:flutter/material.dart';

import '../../core/log.dart';
import '../../state/app_state.dart';
import '../log_line.dart';
import '../widgets.dart';

enum _Filter { all, apdus, problems }

class LogPage extends StatefulWidget {
  const LogPage({super.key, required this.state});

  final AppState state;

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  _Filter _filter = _Filter.all;
  int _shown = 0;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _keep(LogEntry e) {
    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty && !e.text.toLowerCase().contains(q)) return false;
    switch (_filter) {
      case _Filter.all:
        return true;
      case _Filter.apdus:
        return e.kind == LogKind.sent || e.kind == LogKind.received || e.kind == LogKind.blocked;
      case _Filter.problems:
        return e.kind == LogKind.warn || e.kind == LogKind.blocked || (e.kind == LogKind.received && e.sw != 0x9000);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final entries = state.logEntries.where(_keep).toList();
    if (entries.length != _shown) {
      _shown = entries.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'Search the log, for example 6A 86 or SELECT',
                isDense: true,
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SegmentedButton<_Filter>(
            segments: const [
              ButtonSegment(value: _Filter.all, label: Text('All')),
              ButtonSegment(value: _Filter.apdus, label: Text('APDUs')),
              ButtonSegment(value: _Filter.problems, label: Text('Problems')),
            ],
            selected: {_filter},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _filter = s.first),
          ),
          const SizedBox(width: 12),
          IconButton.filledTonal(
            tooltip: 'Save the log as a text file',
            onPressed: state.logEntries.isEmpty ? null : state.saveLog,
            icon: const Icon(Icons.download_rounded),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Clear the log',
            onPressed: state.logEntries.isEmpty ? null : state.clearLog,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      Expanded(
        child: Panel(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: entries.isEmpty
              ? const EmptyState(icon: Icons.receipt_long_rounded, title: 'The log is empty', text: 'Every APDU and its answer appears here.')
              : ListView.builder(
                  controller: _scroll,
                  itemCount: entries.length,
                  itemExtent: null,
                  itemBuilder: (context, i) => LogLine(entry: entries[i]),
                ),
        ),
      ),
    ]);
  }
}

