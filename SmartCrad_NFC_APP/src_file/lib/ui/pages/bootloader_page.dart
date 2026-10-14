import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/card_file.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

/// Make firmware card: turns a meter firmware image into the set of RFID cards that write it to the meter.
///
/// The simple way is to give only the firmware: the tool knows the SOGWAVE 1-phase boards' header recipe (the auth
/// blocks 0x40 and 0xD0), splits the firmware into cards of 117 frames, and makes each card file — the same bytes the
/// Elsewedy utility makes. For a firmware the recipe does not cover (another product, or a size whose last card has a
/// frame-count the recipe has no 0xD0 for), a TEMPLATE set — the cards the utility already made for that product — can
/// be given instead, and its headers are copied. No reader is used; this makes files.
class BootloaderPage extends StatefulWidget {
  const BootloaderPage({super.key, required this.state});

  final AppState state;

  @override
  State<BootloaderPage> createState() => _BootloaderPageState();
}

class _BootloaderPageState extends State<BootloaderPage> {
  static final _product = FirmwareProduct.sogwave1Ph;

  final _firmwarePath = TextEditingController();
  final _version = TextEditingController();
  final _templatePath = TextEditingController();

  Uint8List? _firmware;
  String? _firmwareName;
  String? _firmwareProblem;

  List<CardFrames>? _template;
  String? _templateProblem;

  List<String>? _madePaths;

  /// 0xD0 blocks learned from the utility's own reference card sets kept in the firmware's folder, so the output matches
  /// the utility byte-for-byte for those sizes with no hand-entered value. Filled when a firmware is opened.
  Map<int, String> _learned = {};
  FirmwareProduct get _effProduct => _learned.isEmpty ? _product : _product.withExtraD0(_learned);

  /// The exact version read off the utility's own set for this firmware, when one is in the folder (null otherwise). Used
  /// to fill the version field, since the prefix cannot be told from the file name.
  String? _versionFromReference;

  @override
  void dispose() {
    _firmwarePath.dispose();
    _version.dispose();
    _templatePath.dispose();
    super.dispose();
  }

  // ----- firmware -----

  Future<void> _browseFirmware() async {
    final path = await pickFile(title: 'Choose the meter firmware image', filter: 'Firmware (*.bin)|*.bin|All files (*.*)|*.*');
    if (path != null) _openFirmware(path);
  }

  void _openFirmware(String path) {
    final p = path.trim().replaceAll('"', '');
    setState(() {
      _madePaths = null;
      _firmware = null;
      _firmwareName = null;
      _firmwareProblem = null;
      _learned = {};
      _versionFromReference = null;
      try {
        final raw = File(p).readAsBytesSync();
        if (raw.length % 256 != 0 || raw.isEmpty) {
          _firmwareProblem = 'This firmware is ${raw.length} bytes, not a whole number of 256-byte pages, so it is not a '
              'finished meter image.';
        } else {
          _firmware = Uint8List.fromList(raw);
          _firmwareName = p.split(RegExp(r'[\\/]')).last;
          _firmwarePath.text = p;
          final folder = File(p).parent;
          _learned = _learnFromFolder(folder); // match the utility's 0xD0 from any of its sets kept here
          // the version prefix cannot be told from the file name (GPRS LOCAL uses both b. and g. across builds), so if
          // the utility's own set for THIS firmware is in the folder, take the exact version off it; otherwise fall back
          // to the keyword-based default, which must be confirmed
          _versionFromReference = _readVersionFromReference(folder, _firmwareName!);
          _version.text = _versionFromReference ?? _deriveVersion(_firmwareName!);
        }
      } catch (e) {
        _firmwareProblem = 'Cannot read $p: $e';
      }
    });
  }

  /// Reads any utility reference card files (*_RFID_Card_*.txt/.bin) in [dir] - the folder the firmware is in, where the
  /// utility's own sets are kept - and learns their 0xD0 by frame-count. 0xD0 cannot be computed here (the utility makes
  /// it internally), so reading it off a real card of that size is how the output stays byte-identical, with no manual
  /// entry. Same-family cards only (their 0x40 matches the recipe).
  Map<int, String> _learnFromFolder(Directory dir) {
    if (!dir.existsSync()) return {};
    final cards = <Uint8List>[];
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last.toLowerCase();
      if (!name.contains('rfid_card') || !(name.endsWith('.txt') || name.endsWith('.bin'))) continue;
      try {
        cards.add(CardFile.parse(f.readAsBytesSync()).data);
      } catch (_) {}
    }
    return CardFrames.learnD0(cards, auth40: _product.auth40);
  }

  /// If the utility's own card set for THIS firmware is in [dir] (named `<base>_RFID_Card_N`), reads the exact 5-char
  /// version string off its frames. The version prefix is not a property of the file name (the same product line uses
  /// b. and g. across builds), so a real card of this build is the only reliable source. Null when no matching set is
  /// there, or its version is not 5 printable characters.
  String? _readVersionFromReference(Directory dir, String firmwareName) {
    if (!dir.existsSync()) return null;
    final base = firmwareName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final re = RegExp('^${RegExp.escape(base)}_RFID_Card_\\d+\\.(txt|bin)\$', caseSensitive: false);
    for (final f in dir.listSync().whereType<File>()) {
      if (!re.hasMatch(f.uri.pathSegments.last)) continue;
      try {
        final frames = CardFile.parse(f.readAsBytesSync()).frames;
        if (frames == null || frames.frames.isEmpty) continue;
        final vb = frames.frames.first.versionBytes; // the raw 5 version bytes the card carries
        if (vb.length == 5 && vb.every((b) => b >= 0x20 && b < 0x7F)) return String.fromCharCodes(vb);
      } catch (_) {}
    }
    return null;
  }

  String _deriveVersion(String name) {
    final base = name.replaceAll(RegExp(r'\.[^.]+$'), '');
    final m = RegExp(r'(\d+)$').firstMatch(base);
    if (m == null) return '';
    final number = m.group(1)!;
    final upper = name.toUpperCase();
    var prefix = _product.defaultVersionPrefix;
    for (final e in _product.versionPrefixes.entries) {
      if (upper.contains(e.key)) {
        prefix = e.value;
        break;
      }
    }
    final v = '$prefix$number';
    return v.length <= 5 ? v : v.substring(0, 5);
  }

  // ----- optional template -----

  Future<void> _browseTemplate() async {
    final path = await pickFile(
        title: 'Choose one card of a template set (the others are found automatically)',
        filter: 'Card files (*.txt;*.bin)|*.txt;*.bin|All files (*.*)|*.*');
    if (path != null) _openTemplate(path);
  }

  void _openTemplate(String path) {
    final p = path.trim().replaceAll('"', '');
    setState(() {
      _madePaths = null;
      _template = null;
      _templateProblem = null;
      try {
        final cards = <CardFrames>[];
        for (final pp in _siblings(p)) {
          final frames = CardFile.parse(File(pp).readAsBytesSync(), name: pp.split(RegExp(r'[\\/]')).last).frames;
          if (frames == null) {
            _templateProblem = '${pp.split(RegExp(r'[\\/]')).last} is not a firmware card file.';
            return;
          }
          cards.add(frames);
        }
        cards.sort((a, b) => a.firstSeq.compareTo(b.firstSeq));
        final total = cards.first.total;
        var next = 0;
        for (final c in cards) {
          if (c.total != total || c.firstSeq != next) {
            _templateProblem = 'These files are not one whole set. Pick a card whose siblings _RFID_Card_1.._N are all in the folder.';
            return;
          }
          next = c.lastSeq + 1;
        }
        if (next != total) {
          _templateProblem = 'The set is missing cards: it covers $next of $total frames.';
          return;
        }
        _template = cards;
        _templatePath.text = p;
      } catch (e) {
        _templateProblem = 'Cannot read the template: $e';
      }
    });
  }

  static List<String> _siblings(String path) {
    final file = File(path);
    final name = path.split(RegExp(r'[\\/]')).last;
    final m = RegExp(r'^(.*)_(\d+)(\.[^.]+)$').firstMatch(name);
    if (m == null || !name.toLowerCase().contains('card')) return [path];
    final prefix = '${m.group(1)}_', ext = m.group(3)!;
    final re = RegExp('^${RegExp.escape(prefix)}(\\d+)${RegExp.escape(ext)}\$');
    final found = <(int, String)>[];
    for (final f in file.parent.listSync().whereType<File>()) {
      final mm = re.firstMatch(f.uri.pathSegments.last);
      if (mm != null) found.add((int.parse(mm.group(1)!), f.path));
    }
    if (found.isEmpty) return [path];
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final e in found) e.$2];
  }

  // ----- facts -----

  List<int> get _counts {
    final fw = _firmware;
    if (fw == null) return const [];
    final out = <int>[];
    for (var left = fw.length ~/ 256; left > 0;) {
      final c = left >= _product.framesPerCard ? _product.framesPerCard : left;
      out.add(c);
      left -= c;
    }
    return out;
  }

  // card frame-counts with no utility 0xD0 (built-in or learned from a reference set here); those get a zero reserved
  // 0xD0, which the meter ignores
  Set<int> get _recipeMissing => {for (final c in _counts) if (!_effProduct.d0ByCount.containsKey(c)) c};
  // frame-counts matched to the utility by learning 0xD0 off a reference set in the firmware's folder
  Set<int> get _learnedCounts => {for (final c in _counts) if (_learned.containsKey(c)) c};
  bool get _recipeCanBuild => _firmware != null; // 0xD0 is a reserved block the meter ignores, so any size builds
  bool get _usingTemplate => _template != null;
  bool get _versionOk => _version.text.trim().length == 5;
  bool get _templateFits => _usingTemplate && _firmware != null && _firmware!.length == _template!.first.total * 256;

  bool get _ready {
    if (_firmware == null || !_versionOk) return false;
    return _usingTemplate ? _templateFits : _recipeCanBuild;
  }

  Future<void> _make() async {
    final fw = _firmware;
    if (fw == null) return;
    try {
      final cards = _usingTemplate ? CardFrames.rebuildSet(_template!, firmware: fw) : CardFrames.buildSet(fw, _effProduct, _version.text.trim());
      final base = _firmwareName!.replaceAll(RegExp(r'\.[^.]+$'), '');
      final paths = await widget.state.saveFirmwareCardSet(base, cards);
      if (!mounted) return;
      setState(() => _madePaths = paths);
    } catch (e) {
      widget.state.snack('$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.only(bottom: 12), children: [
      _intro(context),
      const SizedBox(height: 12),
      _firmwarePanel(context),
      const SizedBox(height: 12),
      _templatePanel(context),
      const SizedBox(height: 12),
      _makePanel(context),
    ]);
  }

  Widget _intro(BuildContext context) {
    return Panel(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), gradient: const LinearGradient(colors: [Color(0xFF0D9488), Color(0xFF22D3EE)])),
          child: const Icon(Icons.developer_board_rounded, color: Colors.white, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Make firmware card', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(
                'Give the meter firmware (.bin) and click Make: the tool splits it into the set of cards that flash the '
                'meter, using the built-in ${_product.name} recipe for each card\'s header and auth blocks (0x40 / 0xD0). '
                'The output is the same files the Elsewedy utility makes. No reader is used.',
                style: TextStyle(fontSize: 12.5, color: subtleText(context), height: 1.4)),
          ]),
        ),
      ]),
    );
  }

  Widget _firmwarePanel(BuildContext context) {
    final fw = _firmware;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PanelHeader(icon: Icons.memory_rounded, title: '1. Meter firmware (.bin)'),
        const SizedBox(height: 10),
        _picker(context, _firmwarePath, 'Choose the finished meter firmware image (.bin)', _browseFirmware, filled: true),
        if (_firmwareProblem != null) ...[const SizedBox(height: 10), _bad(context, _firmwareProblem!)],
        if (fw != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(
              width: 170,
              child: TextField(
                controller: _version,
                style: mono(size: 13),
                inputFormatters: [LengthLimitingTextInputFormatter(5)],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Version (5 chars)',
                  hintText: 'e.g. 4.526',
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                  _versionFromReference != null
                      ? 'Taken exactly from the utility\'s own set in this folder — matches that build.'
                      : 'Guessed from the file name (the prefix is not in the name) — check it matches this build.',
                  style: TextStyle(fontSize: 11.5, color: _versionFromReference != null ? okColor : warnColor)),
            ),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _chip(context, Icons.memory_rounded, '${fw.length} bytes', color: okColor),
            _chip(context, Icons.view_module_rounded, '${fw.length ~/ 256} pages'),
            _chip(context, Icons.style_rounded, 'splits into ${_counts.length} cards'),
            _chip(context, Icons.credit_card_rounded, 'frames per card: ${_counts.join(" / ")}'),
            if (!_usingTemplate) ...[
              _chip(context, Icons.verified_rounded, 'recipe builds this', color: okColor),
              if (_learnedCounts.isNotEmpty)
                _chip(context, Icons.auto_awesome_rounded,
                    'matched 0xD0 for ${_learnedCounts.join(" & ")}-frame from a utility set here', color: seed),
              if (_recipeMissing.isNotEmpty)
                _chip(context, Icons.info_outline_rounded,
                    '${_recipeMissing.join(" & ")}-frame card: reserved 0xD0 left 0 (meter ignores it)'),
            ],
          ]),
        ],
      ]),
    );
  }

  Widget _templatePanel(BuildContext context) {
    final t = _template;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PanelHeader(icon: Icons.description_outlined, title: '2. Template set (optional)'),
        const SizedBox(height: 4),
        Text('Only needed for a different product/board than the built-in SOGWAVE 1-phase recipe. For a 1-phase '
            'firmware of any size the recipe alone is enough. Pick one card of an existing set for that product; its '
            'headers are copied.', style: TextStyle(fontSize: 11.5, color: subtleText(context))),
        const SizedBox(height: 10),
        _picker(context, _templatePath, 'Optional: choose ..._RFID_Card_1.txt of a template set', _browseTemplate),
        if (_templateProblem != null) ...[const SizedBox(height: 10), _bad(context, _templateProblem!)],
        if (t != null) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _chip(context, Icons.check_circle_rounded, 'using template: ${t.length} cards, ${t.first.total} frames', color: seed),
            if (_firmware != null && !_templateFits) _chip(context, Icons.error_outline_rounded, 'firmware size ≠ ${t.first.total * 256} B', color: failColor),
          ]),
        ],
      ]),
    );
  }

  Widget _makePanel(BuildContext context) {
    final made = _madePaths;
    final n = _usingTemplate ? _template!.length : _counts.length;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PanelHeader(icon: Icons.save_alt_rounded, title: '3. Make the card files'),
        const SizedBox(height: 6),
        Text('Writes one .txt card file per card to Outputs_Files (hex text only, exactly like the utility - no .bin), '
            'named _RFID_Card_1, _2, ... Write them to the card in order to flash the meter.',
            style: TextStyle(fontSize: 12, color: subtleText(context))),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _ready ? _make : null,
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0D9488)),
            icon: const Icon(Icons.developer_board_rounded, size: 18),
            label: Text(_firmware == null ? 'Make cards' : 'Make $n card${n == 1 ? '' : 's'}'),
          ),
        ),
        if (!_ready) ...[
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded, size: 15, color: warnColor),
            const SizedBox(width: 7),
            Expanded(child: Text(_readyHint(), style: TextStyle(fontSize: 12, color: warnColor))),
          ]),
        ],
        if (made != null && made.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: okColor.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12), border: Border.all(color: okColor.withValues(alpha: 0.4))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.check_circle_rounded, size: 17, color: okColor),
                const SizedBox(width: 8),
                Expanded(child: Text('${made.length} card file${made.length == 1 ? '' : 's'} made', style: const TextStyle(fontWeight: FontWeight.w800))),
              ]),
              const SizedBox(height: 6),
              for (final p in made) SelectableText(p, style: mono(size: 11.5)),
              const SizedBox(height: 4),
              Text('Every CRC was recomputed; saved as .txt hex only, like the utility.', style: TextStyle(fontSize: 11.5, color: subtleText(context))),
            ]),
          ),
        ],
      ]),
    );
  }

  String _readyHint() {
    if (_firmware == null) return 'Choose a meter firmware image (.bin) in step 1 to start.';
    if (!_versionOk) return 'Type a 5-character version (like "4.526") in step 1.';
    if (_usingTemplate && !_templateFits) {
      return 'The firmware is ${_firmware!.length} bytes but the template set holds ${_template!.first.total * 256}. Use a matching template or firmware.';
    }
    return '';
  }

  Widget _picker(BuildContext context, TextEditingController c, String hint, VoidCallback onBrowse, {bool filled = false}) => Row(children: [
        Expanded(
          child: TextField(
            controller: c,
            style: mono(size: 12.5),
            readOnly: true,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(fontSize: 12, color: subtleText(context)),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        const SizedBox(width: 10),
        filled
            ? FilledButton.icon(onPressed: onBrowse, icon: const Icon(Icons.folder_open_rounded, size: 18), label: const Text('Browse'))
            : OutlinedButton.icon(onPressed: onBrowse, icon: const Icon(Icons.folder_open_rounded, size: 18), label: const Text('Browse')),
      ]);

  Widget _chip(BuildContext context, IconData icon, String text, {Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: (color ?? subtleText(context)).withValues(alpha: 0.10), borderRadius: BorderRadius.circular(9)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color ?? subtleText(context)),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color ?? subtleText(context))),
        ]),
      );

  Widget _bad(BuildContext context, String text) => Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: failColor.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10), border: Border.all(color: failColor.withValues(alpha: 0.4))),
        child: Row(children: [
          Icon(Icons.error_outline_rounded, size: 16, color: failColor),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, color: failColor))),
        ]),
      );
}
