import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/card_layout.dart';
import '../../core/card_reader.dart';
import '../../core/hex.dart';
import '../../core/platform.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'block_editor_view.dart';
import 'write_view.dart';

/// Read card: reads the whole card (read-only) and keeps everything that can be read. It shows the data first, then
/// says OK at exactly 32768 bytes or raises an exception, and always writes the HTML data report.
/// The switch at the top turns the page to Write card ([WriteCardView]), which puts bytes into the same file.
class ReadPage extends StatefulWidget {
  const ReadPage({super.key, required this.state});

  final AppState state;

  @override
  State<ReadPage> createState() => _ReadPageState();
}

class _ReadPageState extends State<ReadPage> {
  static const _headerH = 34.0, _rowH = 21.0;
  static const _blockH = _headerH + 16 * _rowH + 10;

  final _hexScroll = ScrollController();
  final _goTo = TextEditingController();
  int? _selectedBlock;
  PhonePlatform? _shownPlatform; // each phone has its own reading: a block picked in one is not kept for the other
  int _mode = 0; // 0 read, 1 write, 2 block editor

  @override
  void dispose() {
    _hexScroll.dispose();
    _goTo.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final state = widget.state;
    await state.readCard();
    if (!mounted) return;
    final r = state.readResult;
    if (r == null) return;
    // first the reading: show where the data ends or the first part that was not read
    final firstGap = r.blocks.where((b) => !b.complete).map((b) => b.index).firstOrNull;
    if (firstGap != null && r.bytesRead > 0) _jumpToBlock(firstGap);
    if (r.ok && r.warnings.isEmpty) {
      final kb = (r.expected / 1024).toStringAsFixed(r.expected % 1024 == 0 ? 0 : 1);
      state.snack('OK: all ${r.expected} bytes ($kb KB) were read. The data report is open in your browser.');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 700)); // let the data show before the message
    if (!mounted) return;
    await _showResultDialog(r);
  }

  Future<void> _showResultDialog(CardReadResult r) async {
    final state = widget.state;
    final missing = r.missing;
    final firstGap = r.blocks.where((b) => !b.complete).map((b) => b.index).firstOrNull;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(r.ok ? Icons.warning_amber_rounded : Icons.error_outline_rounded, color: r.ok ? warnColor : failColor, size: 44),
        title: Text(r.ok ? 'Read card: OK, with warnings' : 'Read card exception'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 420),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(r.message, style: TextStyle(fontWeight: FontWeight.w700, color: r.ok ? warnColor : failColor)),
              const SizedBox(height: 12),
              Text('Read: ${r.bytesRead} of ${r.expected} bytes. Every byte that was read is on the page and in the data report.'),
              if (missing.isNotEmpty && r.bytesRead > 0) ...[
                const SizedBox(height: 12),
                const Text('Not read:', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                for (final m in missing.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('${h4(m.$1)}-${h4(m.$2)}  (${m.$2 - m.$1 + 1} bytes):  ${m.$3}', style: mono(size: 12.5, color: failColor)),
                  ),
                if (missing.length > 8) Text('... and ${missing.length - 8} more parts (see the report)', style: mono(size: 12.5)),
              ],
              if (r.warnings.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Warnings:', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                for (final w in r.warnings)
                  Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• $w', style: const TextStyle(fontSize: 13))),
              ],
            ]),
          ),
        ),
        actions: [
          if (firstGap != null && r.bytesRead > 0)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _jumpToBlock(firstGap);
              },
              icon: const Icon(Icons.search_rounded, size: 18),
              label: const Text('Show the part not read'),
            ),
          if (state.readReportPath != null)
            TextButton.icon(
              onPressed: state.openReadReport,
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('Open data report'),
            ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  void _jumpToBlock(int block) {
    setState(() => _selectedBlock = block);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hexScroll.hasClients) return;
      final target = min(block * _blockH, _hexScroll.position.maxScrollExtent);
      _hexScroll.animateTo(target, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    });
  }

  void _goToOffset(String text) {
    final value = int.tryParse(text.trim(), radix: 16);
    if (widget.state.readResult == null || value == null || value < 0 || value >= widget.state.cardProfile.fileSize) {
      widget.state.snack('Type an offset in hex between 0000 and ${h4(widget.state.cardProfile.lastOffset)}.');
      return;
    }
    _jumpToBlock(value >> 8);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Read card'), icon: Icon(Icons.download_rounded, size: 18)),
            ButtonSegment(value: 1, label: Text('Write card'), icon: Icon(Icons.upload_rounded, size: 18)),
            ButtonSegment(value: 2, label: Text('Block editor'), icon: Icon(Icons.grid_on_rounded, size: 18)),
          ],
          selected: {_mode},
          showSelectedIcon: false,
          onSelectionChanged: state.busy ? null : (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            switch (_mode) {
              1 => 'Writing changes the card. What is there is kept first, so a write can be undone.',
              2 => 'Read a run of 16-byte blocks, edit them, and write only the ones you changed back.',
              _ => 'Reading never changes the card.',
            },
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: subtleText(context)),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      // all three stay built, so switching keeps what was typed, read and edited
      Expanded(
        child: IndexedStack(
          index: _mode,
          sizing: StackFit.expand,
          children: [_readView(context), WriteCardView(state: state), BlockEditorView(state: state)],
        ),
      ),
    ]);
  }

  Widget _readView(BuildContext context) {
    final state = widget.state;
    if (_shownPlatform != state.platform) {
      _shownPlatform = state.platform;
      _selectedBlock = null;
    }
    final r = state.readResult;
    final reading = state.reading;
    final bytes = reading ? state.readProgress : (r?.bytesRead ?? 0);
    final total = r?.expected ?? state.cardProfile.fileSize;
    final progress = bytes / total;
    final totalKb = (total / 1024).toStringAsFixed(total % 1024 == 0 ? 0 : 1);
    final ok = r?.ok;
    final ringColors = ok == false ? const [failColor, Color(0xFFF97316)] : (ok == true ? const [okColor, Color(0xFF14B8A6)] : const [seed, nfcColor]);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        padding: const EdgeInsets.all(18),
        child: Row(children: [
          ProgressRing(
            value: progress.clamp(0.0, 1.0),
            colors: ringColors,
            size: 122,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(bytes == 0 ? '--' : (bytes / 1024).toStringAsFixed(bytes % 1024 == 0 ? 0 : 1),
                  style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
              Text(reading ? 'KB read...' : 'of $totalKb KB', style: TextStyle(fontSize: 12, color: subtleText(context))),
            ]),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Read the whole card, as an ${state.platform.app}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('Reads every 256-byte block from 0000 to ${h4(state.cardProfile.lastOffset)} and keeps everything it can read, even when a part fails. '
                  'Read-only. OK only at exactly ${state.cardProfile.fileSize} bytes; less or more is an exception. '
                  'A data report is made every time.',
                  style: TextStyle(color: subtleText(context), fontSize: 12.5)),
              const SizedBox(height: 10),
              _ResultBanner(state: state, onDetails: r == null || (r.ok && r.warnings.isEmpty) ? null : () => _showResultDialog(r)),
              if (r != null) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _Stat(icon: Icons.data_array_rounded, label: '${r.bytesRead} of ${r.expected} bytes'),
                  _Stat(icon: Icons.timer_outlined, label: '${r.seconds.toStringAsFixed(2)} s · ${r.kbPerSecond.toStringAsFixed(1)} KB/s'),
                  _Stat(icon: Icons.grid_view_rounded, label: '${r.blockKinds.where((k) => k == 'data').length} blocks with data'),
                  _Stat(icon: Icons.fingerprint_rounded, label: 'CRC-32 ${r.crc.toRadixString(16).padLeft(8, '0').toUpperCase()}'),
                  if (r.cardId != null) _Stat(icon: Icons.badge_outlined, label: 'Card ID ${Hex.compact(r.cardId)}'),
                ]),
                _CardContentRow(image: r.image),
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
                  message: state.connected ? 'Read-only: nothing is written to the card' : 'Click Connect at the top first',
                  child: FilledButton.icon(
                    onPressed: state.canRun ? _read : null,
                    icon: reading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4))
                        : const Icon(Icons.download_for_offline_rounded),
                    label: const Text('Read whole card', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: state.readReportPath == null || state.busy ? null : state.openReadReport,
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('Open data report'),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: r == null || r.bytesRead == 0 || state.busy ? null : state.saveReadBin,
                    icon: const Icon(Icons.save_alt_rounded, size: 17),
                    label: const Text('Save .bin'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Tooltip(
                    message: 'One line of hex, the form the Elsewedy Smart Card Utility reads and writes',
                    child: OutlinedButton.icon(
                      onPressed: r == null || r.bytesRead == 0 || state.busy ? null : state.saveReadHexText,
                      icon: const Icon(Icons.text_snippet_outlined, size: 17),
                      label: const Text('Save .txt'),
                    ),
                  ),
                ),
              ]),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: 360, child: _blockMap(context, r)),
          const SizedBox(width: 14),
          Expanded(child: _dataPanel(context, state, r)),
        ]),
      ),
    ]);
  }

  Widget _blockMap(BuildContext context, CardReadResult? r) {
    final kinds = r?.blockKinds ?? const <String>[];
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const PanelHeader(icon: Icons.grid_view_rounded, title: 'Block map (256 bytes each)'),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 16,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 3,
            crossAxisSpacing: 3,
            children: [
              for (var i = 0; i < (r?.blockCount ?? widget.state.cardProfile.blockCount); i++)
                _cell(context, r, i, i < kinds.length ? kinds[i] : 'none'),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 12, runSpacing: 6, children: [
            _legend(context, seed, 'data'),
            _legend(context, borderColor(context), 'all 00'),
            _legend(context, warnColor, 'all FF'),
            _legend(context, warnColor, 'partly read', outline: true),
            _legend(context, failColor, 'not read', outline: true),
          ]),
          const SizedBox(height: 8),
          Text('Click a block to see its bytes.', style: TextStyle(fontSize: 12, color: subtleText(context))),
        ]),
      ),
    );
  }

  Widget _cell(BuildContext context, CardReadResult? r, int i, String kind) {
    final color = switch (kind) {
      'data' => seed,
      'FF' => warnColor,
      '00' => borderColor(context),
      _ => Colors.transparent,
    };
    final border = switch (kind) {
      'partial' => Border.all(color: warnColor, width: 2),
      'missing' => Border.all(color: failColor),
      'none' => Border.all(color: borderColor(context)),
      _ => _selectedBlock == i ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 1.5) : null,
    };
    final block = r == null ? null : r.blocks[i];
    final what = switch (kind) {
      'data' => 'data',
      '00' => 'all 00',
      'FF' => 'all FF',
      'partial' => '${block?.bytes} of 256 bytes read: ${block?.problem}',
      'missing' => 'not read: ${block?.problem}',
      _ => '',
    };
    return Tooltip(
      message: 'Block ${h2(i)}: ${h4(i * 256)}-${h4(i * 256 + 255)}  $what',
      waitDuration: const Duration(milliseconds: 250),
      child: InkWell(
        onTap: r != null && r.bytesRead > 0 ? () => _jumpToBlock(i) : null,
        borderRadius: BorderRadius.circular(4),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4), border: border),
        ),
      ),
    );
  }

  Widget _legend(BuildContext context, Color color, String text, {bool outline = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: outline ? Colors.transparent : color,
            borderRadius: BorderRadius.circular(3),
            border: outline ? Border.all(color: color, width: 1.5) : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: 12, color: subtleText(context))),
      ]);

  Widget _dataPanel(BuildContext context, AppState state, CardReadResult? r) {
    final hasData = r != null && r.bytesRead > 0;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PanelHeader(
          icon: Icons.memory_rounded,
          title: 'Data read from the card',
          trailing: SizedBox(
            width: 190,
            child: TextField(
              controller: _goTo,
              enabled: hasData,
              style: mono(size: 13),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')), LengthLimitingTextInputFormatter(4)],
              onSubmitted: _goToOffset,
              decoration: InputDecoration(
                hintText: 'Go to offset, e.g. 7F00',
                hintStyle: TextStyle(fontSize: 12, color: subtleText(context)),
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 4),
          child: Text('OFFSET  00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F   ASCII     (-- = not read)',
              style: mono(size: 12.5, weight: FontWeight.w700, color: subtleText(context))),
        ),
        const Divider(height: 1),
        Expanded(
          child: !hasData
              ? EmptyState(
                  icon: r?.error != null ? Icons.error_outline_rounded : Icons.download_for_offline_outlined,
                  title: state.reading
                      ? 'Reading...'
                      : (r != null ? 'Nothing could be read' : (state.connected ? 'Nothing read yet' : 'Connect first')),
                  text: state.reading
                      ? '${state.readProgress} bytes so far.'
                      : (r != null
                          ? r.message
                          : (state.connected
                              ? 'Click "Read whole card". The bytes appear here, 256 bytes per block, and in the HTML data report.'
                              : 'Put the card on the reader, choose the reader at the top and click Connect.')),
                )
              : ListView.builder(
                  controller: _hexScroll,
                  itemExtent: _blockH,
                  itemCount: r.blocks.length,
                  itemBuilder: (context, i) => _HexBlock(
                    result: r,
                    block: r.blocks[i],
                    kind: r.blockKinds[i],
                    selected: _selectedBlock == i,
                    headerHeight: _headerH,
                    rowHeight: _rowH,
                  ),
                ),
        ),
      ]),
    );
  }
}

class _ResultBanner extends StatelessWidget {
  const _ResultBanner({required this.state, this.onDetails});

  final AppState state;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final r = state.readResult;
    late final Color color;
    late final IconData icon;
    late final String text;
    if (state.reading) {
      color = nfcColor;
      icon = Icons.sensors_rounded;
      text = 'Reading... ${state.readProgress} of ${state.cardProfile.fileSize} bytes';
    } else if (r == null) {
      color = Theme.of(context).colorScheme.primary;
      icon = Icons.help_outline_rounded;
      text = state.lastError != null && state.page == 2 ? 'Stopped: ${state.lastError}' : 'Not read yet.';
    } else if (r.ok) {
      color = r.warnings.isEmpty ? okColor : warnColor;
      icon = r.warnings.isEmpty ? Icons.verified_rounded : Icons.warning_amber_rounded;
      text = r.message;
    } else {
      color = failColor;
      icon = Icons.error_outline_rounded;
      text = r.message;
    }
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
          child: Text(text,
              maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13.5)),
        ),
        if (onDetails != null) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: onDetails, child: const Text('Details')),
        ],
      ]),
    );
  }
}

/// What the card says about itself: the identity block a meter card carries at its start. Shown only when the card
/// really has one, so a blank or freshly burned card does not get a row of empty labels.
class _CardContentRow extends StatelessWidget {
  const _CardContentRow({required this.image});

  final Uint8List image;

  @override
  Widget build(BuildContext context) {
    final c = CardContent(image);
    if (!c.looksValid) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.badge_outlined, size: 15, color: okColor),
          const SizedBox(width: 6),
          Text('What the card says about itself', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: okColor)),
          if (!c.knownLayout) ...[
            const SizedBox(width: 8),
            Text('format ${c.formatVersion}, not the ${CardContent.knownFormat} these fields were read from',
                style: const TextStyle(fontSize: 11.5, color: warnColor)),
          ],
        ]),
        const SizedBox(height: 5),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final f in CardContent.fields)
            if (c.show(f).isNotEmpty)
              Tooltip(
                message: '${f.name} at ${f.range} (${f.length} bytes)',
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: okColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: okColor.withValues(alpha: 0.30)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('${f.name}  ', style: TextStyle(fontSize: 11, color: subtleText(context))),
                    SelectableText(c.show(f), style: mono(size: 12, weight: FontWeight.w700)),
                  ]),
                ),
              ),
        ]),
      ]),
    );
  }
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

/// One 256-byte block: a heading, then 16 rows of offset, hex and ASCII. Zero bytes are dimmed; bytes that were not
/// read show as -- in red.
class _HexBlock extends StatelessWidget {
  const _HexBlock({
    required this.result,
    required this.block,
    required this.kind,
    required this.selected,
    required this.headerHeight,
    required this.rowHeight,
  });

  final CardReadResult result;
  final BlockRead block;
  final String kind;
  final bool selected;
  final double headerHeight;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    final start = block.start;
    final readEnd = start + block.bytes;
    final data = result.image;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final dim = onSurface.withValues(alpha: 0.28);
    final (tagText, tagColor) = switch (kind) {
      'data' => ('data', seed),
      'FF' => ('all FF', warnColor),
      'partial' => ('partly read', warnColor),
      'missing' => ('not read', failColor),
      _ => ('all 00', subtleText(context)),
    };
    var nonZero = 0;
    for (var i = start; i < readEnd; i++) {
      if (data[i] != 0) nonZero++;
    }
    final bad = !block.complete;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: bad ? failColor.withValues(alpha: 0.06) : (selected ? seed.withValues(alpha: 0.08) : null),
        borderRadius: BorderRadius.circular(10),
        border: selected ? Border.all(color: (bad ? failColor : seed).withValues(alpha: 0.6)) : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: headerHeight,
          child: Row(children: [
            const SizedBox(width: 6),
            Text('Block ${h2(block.index)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            const SizedBox(width: 8),
            Text('${h4(start)}-${h4(start + 255)}', style: mono(size: 12, color: subtleText(context))),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              decoration: BoxDecoration(color: tagColor.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
              child: Text(tagText, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: tagColor)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                bad ? '${block.bytes} of 256 bytes read · ${block.problem ?? 'not read'}' : (kind == 'data' ? '$nonZero non-zero bytes' : ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: bad ? failColor : subtleText(context)),
              ),
            ),
          ]),
        ),
        for (var row = start; row < start + 256; row += 16)
          SizedBox(
            height: rowHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text.rich(
                TextSpan(style: mono(size: 12.5, color: onSurface), children: [
                  TextSpan(text: '${h4(row)}    ', style: TextStyle(color: seed, fontWeight: FontWeight.w700)),
                  for (var i = row; i < row + 16; i++)
                    i < readEnd
                        ? TextSpan(text: '${h2(data[i])}${i - row == 7 ? '  ' : ' '}', style: data[i] == 0 ? TextStyle(color: dim) : null)
                        : TextSpan(text: '--${i - row == 7 ? '  ' : ' '}', style: TextStyle(color: failColor.withValues(alpha: 0.75))),
                  const TextSpan(text: '  '),
                  for (var i = row; i < row + 16; i++)
                    i < readEnd
                        ? TextSpan(
                            text: data[i] >= 0x20 && data[i] < 0x7F ? String.fromCharCode(data[i]) : '.',
                            style: data[i] >= 0x20 && data[i] < 0x7F ? null : TextStyle(color: dim),
                          )
                        : TextSpan(text: '-', style: TextStyle(color: failColor.withValues(alpha: 0.75))),
                ]),
                maxLines: 1,
                softWrap: false,
              ),
            ),
          ),
      ]),
    );
  }
}
