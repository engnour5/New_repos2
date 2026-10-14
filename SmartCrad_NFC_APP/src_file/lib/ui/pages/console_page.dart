import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/apdu.dart';
import '../../core/error_map.dart';
import '../../core/hex.dart';
import '../../core/platform.dart';
import '../../core/status_words.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

class ConsolePage extends StatefulWidget {
  const ConsolePage({super.key, required this.state});

  final AppState state;

  @override
  State<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends State<ConsolePage> {
  final _scroll = ScrollController();
  final _boxFocus = FocusNode();
  int _shown = 0;
  int _historyPos = -1; // -1 = not browsing the history

  @override
  void dispose() {
    _scroll.dispose();
    _boxFocus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    _historyPos = -1;
    await widget.state.sendCommand();
    if (mounted) _boxFocus.requestFocus();
  }

  /// Up and Down in the box walk through the commands sent before.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final history = widget.state.commandHistory;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (history.isEmpty) return KeyEventResult.handled;
      _historyPos = _historyPos < 0 ? history.length - 1 : (_historyPos > 0 ? _historyPos - 1 : 0);
      widget.state.useCommand(history[_historyPos]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_historyPos < 0) return KeyEventResult.handled;
      _historyPos++;
      if (_historyPos >= history.length) {
        _historyPos = -1;
        widget.state.useCommand('');
      } else {
        widget.state.useCommand(history[_historyPos]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _commandPanel(BuildContext context, AppState state) {
    final running = state.busy && state.busyTitle == 'APDU console';
    return Panel(
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const PanelHeader(icon: Icons.keyboard_rounded, title: 'Command'),
          const SizedBox(height: 6),
          Text('Type one APDU in hex and press Send or Enter. Spaces are optional. Up and Down bring back earlier commands.',
              style: TextStyle(fontSize: 12, color: subtleText(context))),
          const SizedBox(height: 12),
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onKey,
            child: TextField(
              controller: state.commandController,
              focusNode: _boxFocus,
              autofocus: true,
              style: mono(size: 17, weight: FontWeight.w600),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F ]')), _UpperCase()],
              onEditingComplete: () {}, // keep the focus in the box after Enter
              onSubmitted: (_) => state.canRun ? _send() : state.snack('Connect first: click Connect at the top.'),
              decoration: InputDecoration(
                hintText: '00 A4 00 00 02 30 40',
                hintStyle: mono(size: 17, color: subtleText(context).withValues(alpha: 0.6)),
                prefixIcon: Padding(
                  padding: const EdgeInsets.only(left: 14, right: 8),
                  child: Text('>>', style: mono(size: 17, weight: FontWeight.w800, color: Theme.of(context).colorScheme.primary)),
                ),
                prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                filled: true,
                fillColor: isDark(context) ? const Color(0xFF0A1022) : const Color(0xFFF7F8FC),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: borderColor(context))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: borderColor(context))),
                suffixIcon: IconButton(
                  tooltip: 'Clear the box',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => state.useCommand(''),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // what the typed bytes mean, while typing
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: state.commandController,
            builder: (context, value, _) => _Breakdown(text: value.text),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: state.canRun ? state.runTap : null,
                icon: const Icon(Icons.nfc_rounded),
                label: const Text('Tap'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: state.commandController,
                builder: (context, value, _) => FilledButton.icon(
                  onPressed: state.canRun && value.text.trim().isNotEmpty ? _send : null,
                  icon: running
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4))
                      : const Icon(Icons.send_rounded),
                  label: Text('Send as ${state.platform.short}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                ),
              ),
            ),
          ]),
          if (!state.connected) ...[
            const SizedBox(height: 8),
            const Text('Connect first, at the top.', style: TextStyle(color: warnColor, fontSize: 12)),
          ],
          const SizedBox(height: 18),
          Text('QUICK COMMANDS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: subtleText(context))),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final q in state.quickCommands.where((q) => !q.writes)) _quickChip(context, state, q),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Icon(Icons.edit_rounded, size: 14, color: warnColor),
            const SizedBox(width: 6),
            Text('THESE CHANGE THE CARD',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: warnColor)),
          ]),
          const SizedBox(height: 4),
          Text('They only fill the box. Edit the bytes, then press Send. SELECT EF 3040 first, or the applet answers 69 86.',
              style: TextStyle(fontSize: 11.5, color: subtleText(context), height: 1.35)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final q in state.quickCommands.where((q) => q.writes)) _quickChip(context, state, q),
          ]),
          if (state.commandHistory.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text('RECENT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: subtleText(context))),
            const SizedBox(height: 4),
            for (final hex in state.commandHistory.reversed.take(8))
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  state.useCommand(hex);
                  _boxFocus.requestFocus();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                  child: Row(children: [
                    Icon(Icons.history_rounded, size: 15, color: subtleText(context)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(hex, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 12.5))),
                  ]),
                ),
              ),
          ],
        ]),
      ),
    );
  }

  /// One quick-command button. The writing ones are amber, so a command that changes the card never looks like a read.
  Widget _quickChip(BuildContext context, AppState state, QuickCommand q) {
    return Tooltip(
      message: q.writes ? '${q.hex}\n\nThis writes to the card. Nothing is sent until you press Send.' : q.hex,
      child: ActionChip(
        avatar: Icon(q.writes ? Icons.edit_rounded : Icons.bolt_rounded, size: 16, color: q.writes ? warnColor : null),
        label: Text(q.label, style: q.writes ? const TextStyle(color: warnColor, fontWeight: FontWeight.w600) : null),
        side: q.writes ? BorderSide(color: warnColor.withValues(alpha: 0.5)) : null,
        backgroundColor: q.writes ? warnColor.withValues(alpha: 0.10) : null,
        onPressed: () {
          state.useCommand(q.hex);
          _boxFocus.requestFocus();
        },
      ),
    );
  }

  void _followNewItems() {
    final n = widget.state.consoleItems.length;
    if (n == _shown) return;
    _shown = n;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    _followNewItems();
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: 470, child: _commandPanel(context, state)),
      const SizedBox(width: 16),
      Expanded(
        child: Panel(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PanelHeader(
              icon: Icons.terminal_rounded,
              title: 'Output',
              trailing: TextButton.icon(
                onPressed: state.consoleItems.isEmpty ? null : state.clearConsole,
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('Clear'),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: state.consoleItems.isEmpty
                  ? EmptyState(
                      icon: Icons.terminal_rounded,
                      title: state.connected ? 'Nothing sent yet' : 'Connect first',
                      text: state.connected
                          ? 'Type a command in the box and click "Send as ${state.platform.short}". Each answer shows its status word, '
                              'its meaning and the data.'
                          : 'Put the card on the reader, choose the reader at the top and click Connect.',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: state.consoleItems.length,
                      itemBuilder: (context, i) => FadeSlideIn(child: _ConsoleTile(item: state.consoleItems[i])),
                    ),
            ),
          ]),
        ),
      ),
    ]);
  }
}

/// Hex letters in capitals as you type.
class _UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

/// The fields of the command in the box: CLA, INS (with its name), P1, P2, offset, Lc, Le. Or what is wrong with it.
class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final digits = text.replaceAll(' ', '');
    if (digits.isEmpty) {
      return Text('The fields of the command show here.', style: TextStyle(fontSize: 12, color: subtleText(context)));
    }
    String message;
    var ok = true;
    if (digits.length.isOdd) {
      message = '${digits.length} hex digits: one is missing (each byte has 2).';
      ok = false;
    } else {
      final bytes = Hex.parse(digits);
      if (bytes.length < 4) {
        message = '${bytes.length} byte${bytes.length == 1 ? '' : 's'}: an APDU needs at least 4 (CLA INS P1 P2).';
        ok = false;
      } else {
        message = '${bytes.length} bytes  ·  ${describeCommand(bytes)}';
        ok = !message.contains('Not a valid');
      }
    }
    final color = ok ? subtleText(context) : warnColor;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(ok ? Icons.info_outline_rounded : Icons.warning_amber_rounded, size: 15, color: color),
      const SizedBox(width: 6),
      Expanded(child: Text(message, style: mono(size: 12, color: color))),
    ]);
  }
}

class _ConsoleTile extends StatelessWidget {
  const _ConsoleTile({required this.item});

  final ConsoleItem item;

  @override
  Widget build(BuildContext context) {
    switch (item.kind) {
      case ConsoleKind.tap:
        return _line(context, Icons.nfc_rounded, item.ok ? nfcColor : failColor, item.text ?? '');
      case ConsoleKind.note:
        return _line(context, Icons.info_outline_rounded, item.ok ? subtleText(context) : failColor, item.text ?? '');
      case ConsoleKind.summary:
        return Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: (item.ok ? okColor : failColor).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(item.ok ? Icons.task_alt_rounded : Icons.error_outline_rounded, color: item.ok ? okColor : failColor, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(item.text ?? '', style: TextStyle(fontWeight: FontWeight.w600, color: item.ok ? okColor : failColor))),
            ]),
          ),
        );
      case ConsoleKind.exchange:
      case ConsoleKind.notSent:
        return _exchange(context);
    }
  }

  Widget _line(BuildContext context, IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 13))),
      ]),
    );
  }

  Widget _exchange(BuildContext context) {
    final r = item.response;
    final sent = item.kind == ConsoleKind.exchange;
    final sw = r?.sw ?? 0;
    final swColor = !sent ? blockedColor : (sw == 0x9000 ? okColor : (r != null && r.sw1 == 0x6C ? warnColor : failColor));
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark(context) ? Colors.white.withValues(alpha: 0.03) : const Color(0xFFF8FAFF),
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: swColor, width: 4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: borderColor(context), borderRadius: BorderRadius.circular(6)),
            child: Text('#${item.lineNo}', style: TextStyle(fontSize: 11, color: subtleText(context))),
          ),
          const SizedBox(width: 10),
          Expanded(child: SelectableText('>> ${Hex.of(item.typed)}', style: mono(size: 13.5, weight: FontWeight.w600))),
          if (item.verdict != null) _verdictChip(item.verdictOk == true, item.verdict!),
        ]),
        if (item.sent != null && !Hex.same(item.sent, item.typed))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('iOS sent it as ${Hex.of(item.sent)}', style: mono(size: 12, color: subtleText(context))),
          ),
        const SizedBox(height: 8),
        if (!sent)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const StatusChip('BLOCKED', dense: true),
            const SizedBox(width: 10),
            Expanded(child: Text(item.reason ?? '', style: const TextStyle(fontSize: 12.5, color: blockedColor))),
          ])
        else ...[
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: swColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
              child: Text('<< ${r!.swText}', style: mono(size: 13, color: swColor, weight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(swMeaning(sw), style: TextStyle(fontSize: 12.5, color: swColor))),
            Text('${item.ms.toStringAsFixed(1)} ms', style: TextStyle(fontSize: 11.5, color: subtleText(context))),
          ]),
          _answerType(context, explainAnswer(item.sent ?? item.typed!, sw)),
          if (r.data.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(_dump(r.data), style: mono(size: 12.5, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85))),
          ],
        ],
      ]),
    );
  }

  /// The type of the answer from the error map: which check of the applet sent it and what to do, or that it is the
  /// ORIGINAL applet's answer. Nothing is shown for a plain success.
  Widget _answerType(BuildContext context, AnswerType a) {
    if (a.kind == AnswerKind.success) return const SizedBox.shrink();
    final color = answerColor(a.kind);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: AnswerChip(a)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.title, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
            if (a.detail.isNotEmpty) Text(a.detail, style: TextStyle(fontSize: 12, color: subtleText(context))),
          ]),
        ),
      ]),
    );
  }

  Widget _verdictChip(bool ok, String text) {
    final color = ok ? okColor : failColor;
    return Tooltip(
      message: text,
      child: Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ok ? Icons.check_rounded : Icons.close_rounded, size: 14, color: color),
          const SizedBox(width: 4),
          Text(ok ? 'as expected' : 'different', style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  static String _dump(List<int> data) {
    final sb = StringBuffer('${data.length} data byte${data.length == 1 ? '' : 's'}');
    for (var i = 0; i < data.length; i += 16) {
      final n = data.length - i < 16 ? data.length - i : 16;
      final ascii = String.fromCharCodes(data.sublist(i, i + n).map((b) => b >= 0x20 && b < 0x7F ? b : 0x2E));
      sb.write('\n${h4(i)}  ${Hex.of(data, i, n).padRight(47)}  $ascii');
    }
    return sb.toString();
  }
}
