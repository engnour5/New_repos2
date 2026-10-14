import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/card_layout.dart';
import '../../core/card_writer.dart';
import '../../core/hex.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

/// Block editor: read a chosen run of 16-byte blocks of EF 3040, edit the bytes in place, and write the changed
/// blocks back. Writing goes through the normal Write card path, so it reads the range first for Undo, writes only
/// the blocks that changed, and reads them back to prove it.
class BlockEditorView extends StatefulWidget {
  const BlockEditorView({super.key, required this.state});

  final AppState state;

  @override
  State<BlockEditorView> createState() => _BlockEditorViewState();
}

class _BlockEditorViewState extends State<BlockEditorView> {
  static const blockSize = 16; // one 16-byte block per row, as the card tools show them
  static const _rowH = 26.0;

  final _startCtl = TextEditingController(text: '0000'); // the start OFFSET in hex, like Read/Write card
  final _countCtl = TextEditingController(text: '16');

  int _offset = 0; // where the read started
  Uint8List? _original; // what the card held when it was read
  final _rows = <TextEditingController>[]; // one per block, 16 bytes of hex each
  final _scroll = ScrollController();

  @override
  void dispose() {
    _startCtl.dispose();
    _countCtl.dispose();
    _scroll.dispose();
    for (final c in _rows) {
      c.dispose();
    }
    super.dispose();
  }

  static int? _hexInt(String s) => s.trim().isEmpty ? null : int.tryParse(s.trim(), radix: 16);

  Future<void> _read() async {
    final state = widget.state;
    final profile = state.cardProfile;
    final last = h4(profile.lastOffset);
    final typed = _hexInt(_startCtl.text);
    final count = int.tryParse(_countCtl.text.trim());
    if (typed == null) {
      state.snack('Type the start offset in hex, 0000 to $last.', error: true);
      return;
    }
    if (count == null || count <= 0) {
      state.snack('Type how many blocks to read.', error: true);
      return;
    }
    // the offset is aligned down to a 16-byte block, so a value like 7FF5 reads the block at 7FF0
    final offset = typed & ~(blockSize - 1);
    final length = count * blockSize;
    if (offset >= profile.fileSize) {
      state.snack('The start offset must be between 0000 and $last.', error: true);
      return;
    }
    if (offset + length > profile.fileSize) {
      state.snack('${h4(offset)} + $count blocks runs past the end of the card ($last). '
          'At most ${(profile.fileSize - offset) ~/ blockSize} block(s) fit from there.', error: true);
      return;
    }
    final data = await state.readBlocks(offset, length);
    if (!mounted || data == null) return;
    setState(() {
      _offset = offset;
      _original = data;
      for (final c in _rows) {
        c.dispose();
      }
      _rows
        ..clear()
        ..addAll([
          for (var i = 0; i < data.length; i += blockSize)
            TextEditingController(text: Hex.of(Hex.sub(data, i, i + blockSize <= data.length ? blockSize : data.length - i))),
        ]);
    });
  }

  /// The bytes the rows now hold, or null and which block is not 16 valid bytes.
  (Uint8List?, int) _edited() {
    final out = Uint8List(_rows.length * blockSize);
    for (var i = 0; i < _rows.length; i++) {
      final Uint8List b;
      try {
        b = Hex.parse(_rows[i].text);
      } on FormatException {
        return (null, i);
      }
      if (b.length != blockSize) return (null, i);
      out.setRange(i * blockSize, i * blockSize + blockSize, b);
    }
    return (out, -1);
  }

  int get _changedBlocks {
    final orig = _original;
    if (orig == null) return 0;
    var n = 0;
    for (var i = 0; i < _rows.length; i++) {
      final here = _rowBytes(i);
      if (here == null || !Hex.same(here, Hex.sub(orig, i * blockSize, blockSize))) n++;
    }
    return n;
  }

  Uint8List? _rowBytes(int i) {
    try {
      final b = Hex.parse(_rows[i].text);
      return b.length == blockSize ? b : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _write() async {
    final state = widget.state;
    final (edited, bad) = _edited();
    if (edited == null) {
      state.snack('Block ${h4(_offset ~/ blockSize + bad)} is not 16 bytes of hex.', error: true);
      setState(() {});
      return;
    }
    if (_changedBlocks == 0) {
      state.snack('No block was changed.');
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: failColor, size: 40),
        title: Text('Write $_changedBlocks changed block${_changedBlocks == 1 ? '' : 's'}?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text('Only the blocks you changed are written, in the range ${h4(_offset)}-${h4(_offset + edited.length - 1)}. '
              'What is there now is read first and kept, so "Undo last write" can put it back.\n\n'
              'Do not take the card off the reader while this runs.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: failColor),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Write changes'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await state.writeCard(CardWriteRequest(_offset, edited, source: 'block editor', fileSize: state.cardProfile.fileSize),
        skipUnchanged: true);
    if (!mounted) return;
    final r = state.writeResult;
    if (r != null && r.ok) {
      // the card now holds what the rows show: this is the new "original" so the diff resets
      setState(() => _original = edited);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final busy = state.busy;
    final has = _original != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          const Icon(Icons.grid_on_rounded, size: 20),
          const SizedBox(width: 10),
          SizedBox(width: 150, child: _numBox(_startCtl, 'Start offset (hex)', busy, hex: true)),
          const SizedBox(width: 10),
          SizedBox(width: 120, child: _numBox(_countCtl, 'How many', busy)),
          const SizedBox(width: 6),
          Text('blocks × 16 bytes', style: TextStyle(fontSize: 12, color: subtleText(context))),
          const SizedBox(width: 16),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              onPressed: state.canRun && !state.blockReading ? _read : null,
              icon: state.blockReading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2.2))
                  : const Icon(Icons.download_rounded, size: 18),
              label: const Text('Read blocks'),
            ),
          ),
          const Spacer(),
          if (has) ...[
            Text('$_changedBlocks changed', style: TextStyle(fontSize: 12.5, color: _changedBlocks > 0 ? warnColor : subtleText(context))),
            const SizedBox(width: 10),
            SizedBox(
              height: 44,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _changedBlocks > 0 ? failColor : null),
                onPressed: state.canRun && _changedBlocks > 0 ? _write : null,
                icon: const Icon(Icons.upload_rounded, size: 18),
                label: const Text('Write changes'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: state.canRun && state.undoable != null ? state.undoLastWrite : null,
              icon: const Icon(Icons.undo_rounded, size: 17),
              label: const Text('Undo'),
            ),
          ],
        ]),
      ),
      if (has && _offset == 0 && _original!.length >= 0x40) ...[
        const SizedBox(height: 10),
        _params(context),
      ],
      const SizedBox(height: 12),
      Expanded(
        child: Panel(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: !has
              ? EmptyState(
                  icon: Icons.grid_on_outlined,
                  title: state.connected ? 'No blocks read yet' : 'Connect first',
                  text: state.connected
                      ? 'Type a start offset (hex, 0000-${h4(state.cardProfile.lastOffset)}) and how many 16-byte blocks to read, then click "Read '
                          'blocks". Edit any byte and click "Write changes" to send only the blocks you changed back to the card.'
                      : 'Put the card on the reader, choose the reader at the top and click Connect.',
                )
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 4),
                    child: Text('BLOCK  OFFSET   16 BYTES (edit here)                              ASCII',
                        style: mono(size: 12.5, weight: FontWeight.w700, color: subtleText(context))),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      controller: _scroll,
                      itemExtent: _rowH,
                      itemCount: _rows.length,
                      itemBuilder: (context, i) => _row(context, i),
                    ),
                  ),
                ]),
        ),
      ),
    ]);
  }

  Widget _params(BuildContext context) {
    final c = CardContent(_original!);
    if (!c.looksValid) return const SizedBox.shrink();
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.badge_outlined, size: 16, color: okColor),
        const SizedBox(width: 8),
        Text('Parameters', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: okColor)),
        const SizedBox(width: 14),
        Expanded(
          child: Wrap(spacing: 8, runSpacing: 6, children: [
            for (final f in CardContent.fields)
              if (c.show(f).isNotEmpty)
                Tooltip(
                  message: '${f.name} at ${f.range}',
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(color: okColor.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(8)),
                    child: Text('${f.name}: ${c.show(f)}', style: mono(size: 11.5)),
                  ),
                ),
          ]),
        ),
      ]),
    );
  }

  Widget _row(BuildContext context, int i) {
    final offset = _offset + i * blockSize;
    final orig = _original!;
    final changed = () {
      final here = _rowBytes(i);
      return here == null || !Hex.same(here, Hex.sub(orig, i * blockSize, blockSize));
    }();
    final bytes = _rowBytes(i);
    final ascii = bytes == null
        ? '????????????????'
        : String.fromCharCodes(bytes.map((b) => b >= 0x20 && b < 0x7F ? b : 0x2E));
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(width: 44, child: Text(h4((_offset ~/ blockSize) + i), style: mono(size: 12, color: subtleText(context)))),
      SizedBox(width: 56, child: Text(h4(offset), style: mono(size: 12, color: changed ? warnColor : subtleText(context)))),
      SizedBox(
        width: 360,
        child: TextField(
          controller: _rows[i],
          enabled: !widget.state.busy,
          style: mono(size: 13, color: changed ? warnColor : null),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F ]')), UpperCaseText()],
          decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 2)),
          onChanged: (_) => setState(() {}),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(ascii, style: mono(size: 12.5, color: bytes == null ? failColor : subtleText(context)), maxLines: 1, overflow: TextOverflow.ellipsis)),
      if (changed) Icon(Icons.edit_rounded, size: 13, color: warnColor),
    ]);
  }

  Widget _numBox(TextEditingController c, String label, bool busy, {bool hex = false}) => TextField(
        controller: c,
        enabled: !busy,
        style: mono(size: 13),
        inputFormatters: hex
            ? [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')), LengthLimitingTextInputFormatter(4), UpperCaseText()]
            : [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
        decoration: InputDecoration(labelText: label, isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
        onChanged: (_) => setState(() {}),
      );
}
