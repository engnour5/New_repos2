import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/card_profile.dart';
import '../../core/hex.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

/// Card profiles: which card the Read, Write and Block-editor screens talk to. The tool was built for the EMG
/// electrometer applet, but a profile holds everything card-specific — the AID(s), how to select the file, how big it
/// is, and the READ/UPDATE commands — so the same screens work with another card. EMG is the default and cannot change.
///
/// Pick a profile on the left to make it the active card; add or change one on the right. The console and the Burner
/// work with any card and ignore the profile.
class CardProfilesPage extends StatefulWidget {
  const CardProfilesPage({super.key, required this.state});

  final AppState state;

  @override
  State<CardProfilesPage> createState() => _CardProfilesPageState();
}

class _CardProfilesPageState extends State<CardProfilesPage> {
  late CardProfile _editing = widget.state.cardProfile;
  bool _isNew = false;

  final _name = TextEditingController();
  final _aids = TextEditingController();
  final _size = TextEditingController();
  final _selectFile = TextEditingController();
  final _idCommand = TextEditingController();
  final _readCla = TextEditingController();
  final _readIns = TextEditingController();
  final _writeCla = TextEditingController();
  final _writeIns = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fill(_editing);
  }

  @override
  void dispose() {
    for (final c in [_name, _aids, _size, _selectFile, _idCommand, _readCla, _readIns, _writeCla, _writeIns]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(CardProfile p) {
    _name.text = p.name;
    _aids.text = p.aidHex;
    _size.text = '${p.fileSize}';
    _selectFile.text = p.selectFile;
    _idCommand.text = p.idCommand;
    _readCla.text = h2(p.readCla);
    _readIns.text = h2(p.readIns);
    _writeCla.text = h2(p.writeCla);
    _writeIns.text = h2(p.writeIns);
  }

  /// A card profile built from what is typed, or a message saying what is wrong.
  (CardProfile?, String?) _fromForm() {
    final name = _name.text.trim();
    if (name.isEmpty) return (null, 'The profile needs a name.');
    final size = _parseSize(_size.text);
    if (size == null) return (null, 'The file size must be a number of bytes (e.g. 32768 or 0x8000).');
    int? byte(TextEditingController c, int fallback) {
      final t = c.text.trim();
      if (t.isEmpty) return fallback;
      final v = int.tryParse(t, radix: 16);
      return (v == null || v < 0 || v > 0xFF) ? null : v;
    }

    final rCla = byte(_readCla, 0x00), rIns = byte(_readIns, 0xB0), wCla = byte(_writeCla, 0x00), wIns = byte(_writeIns, 0xD6);
    if (rCla == null || rIns == null || wCla == null || wIns == null) {
      return (null, 'The READ/UPDATE class and instruction must each be one hex byte (00-FF).');
    }
    final p = CardProfile(
      name: name,
      aidHex: _aids.text.trim(),
      idCommand: _idCommand.text.trim(),
      selectFile: _selectFile.text.trim(),
      fileSize: size,
      readCla: rCla,
      readIns: rIns,
      writeCla: wCla,
      writeIns: wIns,
    );
    return (p, p.problem);
  }

  static int? _parseSize(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return null;
    if (t.startsWith('0x')) return int.tryParse(t.substring(2), radix: 16);
    return int.tryParse(t);
  }

  void _select(CardProfile p) => setState(() {
        _editing = p;
        _isNew = false;
        _fill(p);
      });

  void _newProfile() => setState(() {
        _isNew = true;
        _editing = CardProfile.plainBinary;
        _fill(CardProfile.plainBinary.copyWith(name: 'My card'));
      });

  void _duplicate() => setState(() {
        final (p, _) = _fromForm();
        final base = p ?? _editing;
        _isNew = true;
        _editing = CardProfile.plainBinary; // so the right pane is editable
        _fill(base.copyWith(name: '${base.name} copy'));
      });

  Future<void> _save() async {
    final (p, problem) = _fromForm();
    if (p == null) {
      widget.state.snack(problem!, error: true);
      return;
    }
    await widget.state.addProfile(p);
    if (!mounted) return;
    setState(() {
      _editing = widget.state.cardProfile;
      _isNew = false;
    });
  }

  Future<void> _delete(CardProfile p) async {
    await widget.state.deleteProfile(p);
    if (!mounted) return;
    _select(widget.state.cardProfile);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final readOnly = !_isNew && _editing.builtIn;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _intro(context, state),
      const SizedBox(height: 12),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: 300, child: _listPanel(context, state)),
          const SizedBox(width: 14),
          Expanded(child: _editorPanel(context, state, readOnly)),
        ]),
      ),
    ]);
  }

  Widget _intro(BuildContext context, AppState state) {
    return Panel(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF6366F1)]),
          ),
          child: const Icon(Icons.sim_card_rounded, color: Colors.white, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Card profiles', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(
                'Which card Read, Write and Block editor talk to. EMG is the default; add your own to use the tool with '
                'another ISO 7816 binary-file card. The console and the Burner work with any card and ignore this.',
                style: TextStyle(fontSize: 12.5, color: subtleText(context), height: 1.4)),
          ]),
        ),
        const SizedBox(width: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: okColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: okColor.withValues(alpha: 0.4)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(Icons.check_circle_rounded, size: 15, color: okColor),
              const SizedBox(width: 6),
              Text('ACTIVE CARD', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: okColor, letterSpacing: 0.4)),
            ]),
            const SizedBox(height: 3),
            Text(state.cardProfile.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            Text('${state.cardProfile.fileSize} bytes · 0000-${h4(state.cardProfile.lastOffset)}',
                style: TextStyle(fontSize: 11, color: subtleText(context))),
          ]),
        ),
      ]),
    );
  }

  Widget _listPanel(BuildContext context, AppState state) {
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PanelHeader(icon: Icons.sim_card_rounded, title: 'Profiles'),
        const SizedBox(height: 10),
        Expanded(
          child: ListView(
            children: [
              for (final p in state.profiles)
                _ProfileRow(
                  profile: p,
                  selected: !_isNew && p.name == _editing.name,
                  active: p.name == state.cardProfile.name,
                  onTap: () => _select(p),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: state.busy ? null : _newProfile,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('New profile'),
        ),
      ]),
    );
  }

  Widget _editorPanel(BuildContext context, AppState state, bool readOnly) {
    final isActive = !_isNew && _editing.name == state.cardProfile.name;
    return Panel(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PanelHeader(
          icon: Icons.tune_rounded,
          title: _isNew ? 'New profile' : _editing.name,
          trailing: isActive
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: okColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                  child: Text('active', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: okColor)),
                )
              : null,
        ),
        const SizedBox(height: 12),
        Expanded(child: SingleChildScrollView(child: _form(context, readOnly))),
        const SizedBox(height: 12),
        _actions(context, state, readOnly, isActive),
      ]),
    );
  }

  Widget _actions(BuildContext context, AppState state, bool readOnly, bool isActive) {
    return Row(children: [
      if (!_isNew && !readOnly)
        TextButton.icon(
          onPressed: state.busy ? null : () => _delete(_editing),
          icon: const Icon(Icons.delete_outline_rounded, size: 18, color: failColor),
          label: const Text('Delete', style: TextStyle(color: failColor)),
        ),
      const Spacer(),
      if (!_isNew && !isActive)
        OutlinedButton.icon(
          onPressed: state.busy ? null : () => setState(() => state.setCardProfile(_editing)),
          icon: const Icon(Icons.radio_button_checked_rounded, size: 18),
          label: const Text('Use this card'),
        ),
      if (readOnly) ...[
        const SizedBox(width: 10),
        OutlinedButton.icon(onPressed: _duplicate, icon: const Icon(Icons.copy_rounded, size: 18), label: const Text('Duplicate')),
      ],
      if (!readOnly) ...[
        const SizedBox(width: 10),
        FilledButton.icon(
          onPressed: state.busy ? null : _save,
          icon: const Icon(Icons.save_rounded, size: 18),
          label: Text(_isNew ? 'Add profile' : 'Save and use'),
        ),
      ],
    ]);
  }

  Widget _form(BuildContext context, bool readOnly) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (readOnly)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(color: warnColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Icon(Icons.lock_outline_rounded, size: 16, color: warnColor),
            const SizedBox(width: 8),
            Expanded(
                child: Text('This is a built-in profile. Click "Use this card" to make it active, or "Duplicate" to make one you can change.',
                    style: TextStyle(fontSize: 12, color: warnColor))),
          ]),
        ),
      _field(_name, 'Name', readOnly, hint: 'EMG electrometer'),
      _field(_aids, 'Applet AID(s)', readOnly,
          monoFont: true,
          hint: '45 4D 47 30 30 30 30 30 30 30',
          help: 'The applet(s) a phone would try, in order. Separate several with commas or new lines.'),
      _field(_size, 'File size (bytes)', readOnly, hint: '32768 or 0x8000', help: 'How many bytes the file holds, addressed from 0000.'),
      _field(_selectFile, 'SELECT file APDU', readOnly,
          monoFont: true,
          hint: '00 A4 00 00 02 30 40',
          help: 'How to open the file after the applet is selected. Leave empty when selecting the applet already opens it.'),
      _field(_idCommand, 'Card-ID APDU', readOnly,
          monoFont: true, hint: '80 08 00 00 0A', help: 'Reads the card\'s own ID (GET UID). Leave empty when the card has none.'),
      Row(children: [
        Expanded(child: _field(_readCla, 'READ class', readOnly, monoFont: true, hint: '00')),
        const SizedBox(width: 10),
        Expanded(child: _field(_readIns, 'READ ins', readOnly, monoFont: true, hint: 'B0')),
        const SizedBox(width: 10),
        Expanded(child: _field(_writeCla, 'UPDATE class', readOnly, monoFont: true, hint: '00')),
        const SizedBox(width: 10),
        Expanded(child: _field(_writeIns, 'UPDATE ins', readOnly, monoFont: true, hint: 'D6')),
      ]),
      const SizedBox(height: 6),
      Text('READ BINARY and UPDATE BINARY are the ISO 7816 defaults (B0 / D6). Change them only for a card that uses other commands.',
          style: TextStyle(fontSize: 11.5, color: subtleText(context))),
    ]);
  }

  Widget _field(TextEditingController c, String label, bool readOnly, {bool monoFont = false, String? hint, String? help}) {
    final field = TextField(
      controller: c,
      enabled: !readOnly,
      style: monoFont ? mono(size: 13) : const TextStyle(fontSize: 13),
      inputFormatters: monoFont && (c == _readCla || c == _readIns || c == _writeCla || c == _writeIns)
          ? [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')), LengthLimitingTextInputFormatter(2), UpperCaseText()]
          : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(fontSize: 12, color: subtleText(context)),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: help == null
          ? field
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              field,
              Padding(
                padding: const EdgeInsets.only(top: 3, left: 2),
                child: Text(help, style: TextStyle(fontSize: 11, color: subtleText(context))),
              ),
            ]),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.profile, required this.selected, required this.active, required this.onTap});

  final CardProfile profile;
  final bool selected, active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? seed.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? seed.withValues(alpha: 0.5) : borderColor(context)),
        ),
        child: Row(children: [
          Icon(active ? Icons.check_circle_rounded : Icons.sim_card_outlined, size: 17, color: active ? okColor : subtleText(context)),
          const SizedBox(width: 9),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(profile.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
              Text('${profile.fileSize} bytes${profile.builtIn ? ' · built-in' : ''}',
                  style: TextStyle(fontSize: 11, color: subtleText(context))),
            ]),
          ),
        ]),
      ),
    );
  }
}
