import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/card_layout.dart';
import '../../core/hex.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

/// Read Company ID: the same thing the Elsewedy Smart Card Utility's "Read Company ID" does - reads the card's identity
/// block (the first 64 bytes: card ID, company, region, firmware/format version) and shows it, in one fast read instead
/// of the whole 32 KB. The fields are decoded by [CardContent]; the read uses the active card profile.
class CompanyIdPage extends StatefulWidget {
  const CompanyIdPage({super.key, required this.state});

  final AppState state;

  @override
  State<CompanyIdPage> createState() => _CompanyIdPageState();
}

class _CompanyIdPageState extends State<CompanyIdPage> {
  static const _identityLen = 64; // the identity block: CardContent fields 0x00..0x3F

  bool _reading = false;
  Uint8List? _identity;

  Future<void> _read() async {
    if (_reading || widget.state.busy) return;
    if (!widget.state.connected) {
      widget.state.snack('Connect to a reader first.');
      return;
    }
    setState(() => _reading = true);
    final bytes = await widget.state.readBlocks(0, _identityLen, label: 'Read Company ID');
    if (!mounted) return;
    setState(() {
      if (bytes != null) _identity = bytes;
      _reading = false;
    });
  }

  void _copy(String v) {
    Clipboard.setData(ClipboardData(text: v));
    widget.state.snack('Copied: $v');
  }

  @override
  Widget build(BuildContext context) {
    final id = _identity;
    return ListView(padding: const EdgeInsets.only(bottom: 12), children: [
      _intro(context),
      const SizedBox(height: 12),
      _actionPanel(context),
      if (id != null) ...[
        const SizedBox(height: 12),
        _resultPanel(context, CardContent(id)),
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
                gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF34D399)])),
            child: const Icon(Icons.badge_rounded, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Read Company ID', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(
                  'The same as the Elsewedy utility\'s "Read Company ID": reads the card\'s identity block - card ID, '
                  'company, region, firmware and format version - in one fast read of the first 64 bytes, not the whole '
                  '32 KB. Uses the active card profile. A blank or freshly burned card simply has no identity block.',
                  style: TextStyle(fontSize: 12.5, color: subtleText(context), height: 1.4)),
            ]),
          ),
        ]),
      );

  Widget _actionPanel(BuildContext context) {
    final connected = widget.state.connected;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: (connected && !widget.state.busy && !_reading) ? _read : null,
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            icon: _reading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : const Icon(Icons.badge_rounded, size: 18),
            label: Text(_reading ? 'Reading…' : 'Read Company ID'),
          ),
        ),
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
      ]),
    );
  }

  Widget _resultPanel(BuildContext context, CardContent c) {
    if (!c.looksValid) {
      return Panel(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, size: 18, color: warnColor),
          const SizedBox(width: 10),
          Expanded(
              child: Text(
                  'This card has no company / identity block - the first bytes are not a company and a version. A blank '
                  'or freshly burned card reads like this.',
                  style: TextStyle(fontSize: 13, color: subtleText(context)))),
        ]),
      );
    }
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PanelHeader(icon: Icons.badge_outlined, title: 'What the card says about itself'),
        if (!c.knownLayout) ...[
          const SizedBox(height: 6),
          Row(children: [
            Icon(Icons.warning_amber_rounded, size: 15, color: warnColor),
            const SizedBox(width: 6),
            Expanded(
                child: Text(
                    'Format ${c.formatVersion}, not the ${CardContent.knownFormat} these fields were read from - the '
                    'layout may have moved, so check the values.',
                    style: TextStyle(fontSize: 11.5, color: warnColor))),
          ]),
        ],
        const SizedBox(height: 12),
        _hero(context, 'Company ID', c.companyId.isEmpty ? '—' : c.companyId),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in CardContent.fields)
            if (f.name != 'Company ID' && c.show(f).isNotEmpty) _fieldChip(context, f, c.show(f)),
        ]),
        const SizedBox(height: 14),
        Text('Identity block (first $_identityLen bytes)', style: TextStyle(fontSize: 11, color: subtleText(context))),
        const SizedBox(height: 4),
        SelectableText(Hex.of(_identity!), style: mono(size: 11, color: subtleText(context))),
      ]),
    );
  }

  Widget _hero(BuildContext context, String label, String value) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
        decoration: BoxDecoration(
            color: okColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: okColor.withValues(alpha: 0.35))),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12, color: subtleText(context), fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              SelectableText(value, style: mono(size: 22, weight: FontWeight.w800)),
            ]),
          ),
          IconButton(
              tooltip: 'Copy', onPressed: value == '—' ? null : () => _copy(value), icon: const Icon(Icons.copy_rounded, size: 18)),
        ]),
      );

  Widget _fieldChip(BuildContext context, CardField f, String value) => Tooltip(
        message: '${f.name} at ${f.range} (${f.length} bytes) — click to copy',
        child: InkWell(
          onTap: () => _copy(value),
          borderRadius: BorderRadius.circular(9),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: okColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: okColor.withValues(alpha: 0.30))),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${f.name}  ', style: TextStyle(fontSize: 11, color: subtleText(context))),
              Text(value, style: mono(size: 12.5, weight: FontWeight.w700)),
            ]),
          ),
        ),
      );
}
