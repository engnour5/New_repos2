import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/card_file.dart';
import '../../core/card_layout.dart';
import '../../core/card_writer.dart';
import '../../core/hex.dart';
import '../../core/platform.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

enum _Source { hex, file, fill }

/// Write card: puts bytes into the card's 32 KB file (EF 3040) and proves it by reading them back. What was there
/// before is read first and kept, so the write can be undone, and saved as a backup file.
class WriteCardView extends StatefulWidget {
  const WriteCardView({super.key, required this.state});

  final AppState state;

  @override
  State<WriteCardView> createState() => _WriteCardViewState();
}

class _WriteCardViewState extends State<WriteCardView> {
  static const _rowH = 21.0;

  var _source = _Source.hex;
  final _offset = TextEditingController(text: '0000');
  final _hex = TextEditingController();
  final _filePath = TextEditingController();
  final _fileOffset = TextEditingController(text: '0000');
  final _fillFrom = TextEditingController(text: '0000');
  final _fillTo = TextEditingController(text: '00FF');
  final _fillByte = TextEditingController(text: '00');
  Uint8List? _fileBytes;
  CardFileFormat? _fileFormat;
  String? _fileWhat; // what the file turned out to be: a firmware card, or a meter card
  String? _fileProblem;
  bool _skipUnchanged = true;

  /// True once the boxes no longer describe the last write, so the bytes panel shows what would be written next.
  bool _edited = true;

  @override
  void dispose() {
    for (final c in [_offset, _hex, _filePath, _fileOffset, _fillFrom, _fillTo, _fillByte]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() => setState(() => _edited = true);

  static int? _offsetOf(String text) => text.trim().isEmpty ? null : int.tryParse(text.trim(), radix: 16);

  /// The write the boxes describe, and why it cannot be made (null when it can).
  (CardWriteRequest?, String?) _request() {
    final fs = widget.state.cardProfile.fileSize;
    final last = h4(widget.state.cardProfile.lastOffset);
    switch (_source) {
      case _Source.hex:
        final offset = _offsetOf(_offset.text);
        if (offset == null) return (null, 'Type the offset in hex, 0000 to $last.');
        if (_hex.text.trim().isEmpty) return (null, 'Type the bytes to write, in hex.');
        final Uint8List data;
        try {
          data = Hex.parse(_hex.text);
        } on FormatException catch (e) {
          return (null, e.message);
        }
        final request = CardWriteRequest(offset, data, source: 'typed', fileSize: fs);
        return (request, request.problem);
      case _Source.file:
        final bytes = _fileBytes;
        if (bytes == null) return (null, _fileProblem ?? 'Choose a .bin file.');
        final offset = _offsetOf(_fileOffset.text);
        if (offset == null) return (null, 'Type the offset in hex, 0000 to $last.');
        final request = CardWriteRequest(offset, bytes, source: _filePath.text.split(RegExp(r'[\\/]')).last, fileSize: fs);
        return (request, request.problem);
      case _Source.fill:
        final from = _offsetOf(_fillFrom.text), to = _offsetOf(_fillTo.text), byte = _offsetOf(_fillByte.text);
        if (from == null || to == null) return (null, 'Type the first and the last offset in hex.');
        if (byte == null || byte > 0xFF) return (null, 'Type the fill byte in hex, 00 to FF.');
        if (to < from) return (null, 'The last offset comes before the first.');
        final request = CardWriteRequest(from, Uint8List(to - from + 1)..fillRange(0, to - from + 1, byte),
            source: 'fill ${h2(byte)}', fileSize: fs);
        return (request, request.problem);
    }
  }

  Future<void> _browse() async {
    final path = await pickFile(
        title: 'Choose the card file to write',
        filter: 'Card files (*.bin;*.txt)|*.bin;*.txt|Card data (*.bin)|*.bin|Hex text (*.txt)|*.txt|All files (*.*)|*.*');
    if (path == null || !mounted) return;
    await _openFile(path);
  }

  Future<void> _openFile(String path) async {
    final p = path.trim().replaceAll('"', ''); // Explorer's "Copy as path" puts it in quotes
    try {
      final raw = await File(p).readAsBytes();
      // a .bin from this app, or the hex text the Smart Card Utility and the *_RFID_Card_*.txt files use
      final file = CardFile.parse(raw, name: p.split(RegExp(r'[\\/]')).last);
      final bytes = file.data;
      if (!mounted) return;
      setState(() {
        _filePath.text = p;
        _fileBytes = bytes.isEmpty ? null : bytes;
        _fileFormat = file.format;
        _fileWhat = _describe(file);
        _fileProblem = bytes.isEmpty ? 'The file is empty.' : null;
        // a backup that Write card made is named after its range: it goes back where it came from
        final m = RegExp(r'card_backup_([0-9A-Fa-f]{4})-').firstMatch(p.split(RegExp(r'[\\/]')).last);
        if (m != null) {
          _fileOffset.text = m.group(1)!.toUpperCase();
        } else if (bytes.length == widget.state.cardProfile.fileSize) {
          _fileOffset.text = '0000';
        }
        _edited = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fileBytes = null;
        _fileFormat = null;
        _fileWhat = null;
        _fileProblem = e is FormatException ? e.message : 'Cannot read $p: $e';
        _edited = true;
      });
    }
  }

  /// What the chosen file turned out to be, so you know before writing it.
  static String? _describe(CardFile file) {
    final frames = file.frames;
    if (frames != null) {
      return '${frames.summary}\nIt is written at 0000, as the tools that made it do. The byte after each frame is '
          'kept as it is: this app does not work it out, so only a file made elsewhere should be written.';
    }
    final content = CardContent(file.data);
    return content.looksValid ? 'Meter card: ${content.summary}' : null;
  }

  Future<bool> _confirm(String title, String question, String action, {bool danger = true}) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(danger ? Icons.warning_amber_rounded : Icons.undo_rounded, color: danger ? failColor : null, size: 40),
        title: Text(title),
        content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: Text(question)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: failColor) : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return go == true;
  }

  Future<void> _write() async {
    final state = widget.state;
    final (request, problem) = _request();
    if (request == null || problem != null) {
      state.snack(problem ?? 'There is nothing to write.', error: true);
      return;
    }
    final ok = await _confirm(
      'Write ${request.length} bytes to the card?',
      'They go into the card\'s file at ${request.range} and replace what is there now. What is there now is read '
          'first and kept, so "Undo last write" can put it back, and it is saved as card_backup_${request.range}_*.bin '
          'in the Outputs_Files folder beside the app.\n\nDo not take the card off the reader while this runs.',
      'Write it',
    );
    if (!ok || !mounted) return;
    setState(() => _edited = false);
    await state.writeCard(request, skipUnchanged: _skipUnchanged);
  }

  Future<void> _undo() async {
    final state = widget.state;
    final u = state.undoable;
    if (u == null) return;
    final ok = await _confirm(
      'Undo the last write?',
      'The ${u.done} bytes at ${h4(u.request.offset)}-${h4(u.request.offset + u.done - 1)} get back what they held '
          'before the write. This only goes to the card the write was made on'
          '${u.cardId == null ? '' : ' (card ID ${Hex.compact(u.cardId)})'}.',
      'Undo it',
      danger: false,
    );
    if (!ok || !mounted) return;
    setState(() => _edited = false);
    await state.undoLastWrite();
  }

  static String _size(int bytes) => bytes >= 1024 ? '${(bytes / 1024).toStringAsFixed(bytes % 1024 == 0 ? 0 : 1)} KB' : '$bytes';

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final (request, problem) = _request();
    final result = _edited ? null : state.writeResult;
    final shown = result?.request ?? (problem == null ? request : null);
    final total = shown?.length ?? 0;
    final done = state.writing ? state.writeProgress : (result?.done ?? 0);
    final ringColors = result == null
        ? const [seed, nfcColor]
        : (result.ok ? (result.warnings.isEmpty ? const [okColor, Color(0xFF14B8A6)] : const [warnColor, okColor]) : const [failColor, Color(0xFFF97316)]);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        padding: const EdgeInsets.all(18),
        child: Row(children: [
          ProgressRing(
            value: total == 0 ? 0 : (done / total).clamp(0.0, 1.0),
            colors: ringColors,
            size: 122,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(done == 0 && result == null ? '--' : _size(done), style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
              Text(state.writing ? 'written...' : (total == 0 ? 'bytes' : 'of ${_size(total)}${total < 1024 ? ' bytes' : ''}'),
                  style: TextStyle(fontSize: 12, color: subtleText(context))),
            ]),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Write the card, as an ${state.platform.app}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('Puts bytes into the card\'s 32 KB file with UPDATE BINARY, then reads them back to prove it. What was '
                  'there is read first and kept, so the write can be undone.',
                  style: TextStyle(color: subtleText(context), fontSize: 12.5)),
              const SizedBox(height: 10),
              _banner(context, state, result, request, problem),
              if (result != null) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _Stat(icon: Icons.data_array_rounded, label: '${result.done} of ${result.request.length} bytes'),
                  _Stat(icon: Icons.upload_rounded, label: '${result.bytesSent} sent in ${result.partsWritten} UPDATE'),
                  if (result.partsSkipped > 0)
                    _Stat(icon: Icons.done_all_rounded, label: '${result.partsSkipped} part${result.partsSkipped == 1 ? '' : 's'} already right'),
                  _Stat(icon: Icons.timer_outlined, label: '${result.seconds.toStringAsFixed(2)} s'),
                  if (result.cardId != null) _Stat(icon: Icons.badge_outlined, label: 'Card ID ${Hex.compact(result.cardId)}'),
                  if (result.backupPath != null) _Stat(icon: Icons.inventory_2_outlined, label: result.backupPath!.split('\\').last),
                ]),
              ],
            ]),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 210,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                height: 48,
                child: Tooltip(
                  message: state.connected ? 'Asks first. What is there now is kept, so it can be undone.' : 'Click Connect at the top first',
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: failColor),
                    onPressed: state.canRun && request != null && problem == null ? _write : null,
                    icon: state.writing
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4))
                        : const Icon(Icons.upload_rounded),
                    label: const Text('Write to card', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: state.canRun && state.undoable != null ? _undo : null,
                icon: const Icon(Icons.undo_rounded, size: 18),
                label: const Text('Undo last write'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: state.busy || (state.writeResult?.backupPath ?? state.undoable?.backupPath) == null ? null : state.openWriteBackup,
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                label: const Text('Show backup'),
              ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: 400, child: _inputPanel(context, state, request, problem)),
          const SizedBox(width: 14),
          Expanded(child: _bytesPanel(context, state, shown, result, problem)),
        ]),
      ),
    ]);
  }

  Widget _banner(BuildContext context, AppState state, CardWriteResult? result, CardWriteRequest? request, String? problem) {
    late final Color color;
    late final IconData icon;
    late final String text;
    if (state.writing) {
      color = nfcColor;
      icon = Icons.sensors_rounded;
      text = 'Writing... ${state.writeProgress} bytes done';
    } else if (result != null) {
      color = result.ok ? (result.warnings.isEmpty ? okColor : warnColor) : failColor;
      icon = result.ok ? (result.warnings.isEmpty ? Icons.verified_rounded : Icons.warning_amber_rounded) : Icons.error_outline_rounded;
      text = result.message;
    } else if (problem != null || request == null) {
      color = Theme.of(context).colorScheme.primary;
      icon = Icons.edit_note_rounded;
      text = problem ?? 'Say what to write on the left.';
    } else {
      color = Theme.of(context).colorScheme.primary;
      icon = Icons.help_outline_rounded;
      text = 'Ready: ${request.length} bytes at ${request.range}. Nothing is written until you click "Write to card".';
    }
    final warnings = result?.warnings ?? const <String>[];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13.5)),
        ),
        if (warnings.isNotEmpty) ...[
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                icon: const Icon(Icons.warning_amber_rounded, color: warnColor, size: 40),
                title: const Text('Write card: warnings'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      for (final w in warnings) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $w')),
                    ]),
                  ),
                ),
                actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
              ),
            ),
            child: const Text('Details'),
          ),
        ],
      ]),
    );
  }

  // ------------------------------------------------------------------ what to write

  Widget _inputPanel(BuildContext context, AppState state, CardWriteRequest? request, String? problem) {
    final busy = state.busy;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const PanelHeader(icon: Icons.edit_note_rounded, title: 'What to write'),
          const SizedBox(height: 10),
          SegmentedButton<_Source>(
            segments: const [
              ButtonSegment(value: _Source.hex, label: Text('Hex bytes'), icon: Icon(Icons.keyboard_alt_outlined, size: 18)),
              ButtonSegment(value: _Source.file, label: Text('.bin file'), icon: Icon(Icons.insert_drive_file_outlined, size: 18)),
              ButtonSegment(value: _Source.fill, label: Text('Fill'), icon: Icon(Icons.format_color_fill_rounded, size: 18)),
            ],
            selected: {_source},
            showSelectedIcon: false,
            onSelectionChanged: busy ? null : (s) => setState(() {
              _source = s.first;
              _edited = true;
            }),
          ),
          const SizedBox(height: 14),
          ...switch (_source) {
            _Source.hex => [
                _offsetBox(_offset, 'Offset (hex)', busy),
                const SizedBox(height: 10),
                TextField(
                  controller: _hex,
                  enabled: !busy,
                  minLines: 4,
                  maxLines: 8,
                  style: mono(size: 12.5),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F \n]')), UpperCaseText()],
                  decoration: InputDecoration(
                    labelText: 'Bytes (hex)',
                    hintText: 'e.g. 45 4D 47 20 54 45 53 54',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onChanged: (_) => _changed(),
                ),
              ],
            _Source.file => [
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _filePath,
                      enabled: !busy,
                      style: mono(size: 12),
                      decoration: InputDecoration(labelText: 'File', isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
                      onSubmitted: busy ? null : _openFile,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: busy ? null : _browse, child: const Text('Browse')),
                ]),
                const SizedBox(height: 10),
                _offsetBox(_fileOffset, 'Write it at offset (hex)', busy),
                if (_fileFormat != null && _fileBytes != null) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    Icon(Icons.description_outlined, size: 15, color: subtleText(context)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Read as ${_fileFormat!.label}: ${_fileBytes!.length} bytes',
                          style: mono(size: 12, color: subtleText(context))),
                    ),
                  ]),
                  if (_fileWhat != null) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: nfcColor.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: nfcColor.withValues(alpha: 0.30)),
                      ),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.info_outline_rounded, size: 15, color: nfcColor),
                        const SizedBox(width: 7),
                        Expanded(child: Text(_fileWhat!, style: TextStyle(fontSize: 11.5, color: nfcColor, height: 1.35))),
                      ]),
                    ),
                  ],
                ],
                const SizedBox(height: 6),
                Text(
                  'A .bin from "Save .bin", or a card file in hex text as the Smart Card Utility and the '
                  '*_RFID_Card_*.txt files keep it. 32768 bytes written at 0000 puts the whole card back, and a '
                  'card_backup_*.bin goes back to the offset in its name by itself.',
                  style: TextStyle(fontSize: 12, color: subtleText(context), height: 1.35),
                ),
              ],
            _Source.fill => [
                Row(children: [
                  Expanded(child: _offsetBox(_fillFrom, 'From (hex)', busy)),
                  const SizedBox(width: 8),
                  Expanded(child: _offsetBox(_fillTo, 'To (hex)', busy)),
                  const SizedBox(width: 8),
                  SizedBox(width: 92, child: _offsetBox(_fillByte, 'Byte', busy, digits: 2)),
                ]),
                const SizedBox(height: 6),
                Text('Every byte from the first offset to the last one, both included, becomes this byte. 00 clears '
                    'that part of the card.',
                    style: TextStyle(fontSize: 12, color: subtleText(context), height: 1.35)),
              ],
          },
          const SizedBox(height: 10),
          Row(children: [
            Icon(problem == null ? Icons.check_circle_rounded : Icons.info_outline_rounded, size: 17, color: problem == null ? okColor : warnColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                problem ?? '${request!.length} byte${request.length == 1 ? '' : 's'}  ->  ${request.range}',
                style: problem == null ? mono(size: 12.5, color: okColor) : const TextStyle(fontSize: 12.5, color: warnColor),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          InkWell(
            onTap: busy ? null : () => setState(() => _skipUnchanged = !_skipUnchanged),
            borderRadius: BorderRadius.circular(8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 34,
                height: 34,
                child: Checkbox(value: _skipUnchanged, onChanged: busy ? null : (v) => setState(() => _skipUnchanged = v ?? true)),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Skip parts that already hold these bytes', style: TextStyle(fontSize: 13)),
                    Text('Only the parts that differ are written: quicker, and fewer writes for the card\'s memory.',
                        style: TextStyle(fontSize: 11.5, color: subtleText(context), height: 1.3)),
                  ]),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.shield_outlined, size: 15, color: warnColor)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Before anything is written, the bytes there now are read and kept for "Undo last write", and saved '
                'as card_backup_<range>.bin in the Outputs_Files folder. Undo only goes to the card the write was '
                'made on.',
                style: TextStyle(fontSize: 11.5, color: subtleText(context), height: 1.35),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _offsetBox(TextEditingController c, String label, bool busy, {int digits = 4}) => TextField(
        controller: c,
        enabled: !busy,
        style: mono(size: 13),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')), LengthLimitingTextInputFormatter(digits), UpperCaseText()],
        decoration: InputDecoration(labelText: label, isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
        onChanged: (_) => _changed(),
      );

  // ------------------------------------------------------------------ the bytes

  Widget _bytesPanel(BuildContext context, AppState state, CardWriteRequest? shown, CardWriteResult? result, String? problem) {
    final first = shown == null ? 0 : shown.offset & ~0xF;
    final rows = shown == null ? 0 : ((shown.last | 0xF) - first + 1) ~/ 16;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PanelHeader(
          icon: Icons.memory_rounded,
          title: result != null ? 'Written to the card' : 'Bytes to write',
          trailing: result == null
              ? null
              : Wrap(spacing: 12, children: [
                  _legend(context, seed, 'changed'),
                  _legend(context, subtleText(context), 'already the same'),
                  if (result.after != null) _legend(context, failColor, 'wrong on read-back'),
                ]),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 4),
          child: Text('OFFSET  00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F   ASCII',
              style: mono(size: 12.5, weight: FontWeight.w700, color: subtleText(context))),
        ),
        const Divider(height: 1),
        Expanded(
          child: shown == null
              ? EmptyState(
                  icon: Icons.upload_file_outlined,
                  title: state.connected ? 'Nothing to write yet' : 'Connect first',
                  text: problem ??
                      'Type bytes, choose a .bin file or set a fill on the left. They are shown here before anything is '
                          'written.',
                )
              : ListView.builder(
                  itemExtent: _rowH,
                  itemCount: rows,
                  itemBuilder: (context, i) => _row(context, shown, result, first + i * 16),
                ),
        ),
      ]),
    );
  }

  Widget _row(BuildContext context, CardWriteRequest shown, CardWriteResult? result, int rowStart) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final dim = onSurface.withValues(alpha: 0.32);
    TextStyle? styleOf(int i) {
      if (result == null) return null;
      final after = result.after;
      if (after != null && after[i] != shown.data[i]) return const TextStyle(color: failColor, fontWeight: FontWeight.w800);
      final before = result.before;
      if (before != null && i < result.done && before[i] != shown.data[i]) return const TextStyle(color: seed, fontWeight: FontWeight.w800);
      return TextStyle(color: dim);
    }

    final hex = <TextSpan>[], ascii = <TextSpan>[];
    for (var o = rowStart; o < rowStart + 16; o++) {
      final gap = o - rowStart == 7 ? '  ' : ' ';
      if (o < shown.offset || o > shown.last) {
        hex.add(TextSpan(text: '  $gap'));
        ascii.add(const TextSpan(text: ' '));
        continue;
      }
      final i = o - shown.offset;
      final b = shown.data[i];
      final style = styleOf(i);
      hex.add(TextSpan(text: '${h2(b)}$gap', style: style));
      ascii.add(TextSpan(text: b >= 0x20 && b < 0x7F ? String.fromCharCode(b) : '.', style: style ?? (b >= 0x20 && b < 0x7F ? null : TextStyle(color: dim))));
    }
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Text.rich(
        TextSpan(style: mono(size: 12.5, color: onSurface), children: [
          TextSpan(text: '${h4(rowStart)}    ', style: const TextStyle(color: seed, fontWeight: FontWeight.w700)),
          ...hex,
          const TextSpan(text: '  '),
          ...ascii,
        ]),
        maxLines: 1,
        softWrap: false,
      ),
    );
  }

  Widget _legend(BuildContext context, Color color, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(fontSize: 11.5, color: subtleText(context))),
      ]);
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: borderColor(context), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: subtleText(context)),
        const SizedBox(width: 6),
        Text(label, style: mono(size: 12)),
      ]),
    );
  }
}
