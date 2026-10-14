import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/hex.dart';
import '../../gp/batch_burn.dart';
import '../../gp/card_manager.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

/// The card manager screen: open a secure channel with the card's own keys, see the packages and applets that are on
/// it, select one, delete one, or load a CAP file and install it.
///
/// Everything here goes straight to the reader. No phone can send these commands, so the iPhone and Android rules do
/// not apply on this page.
class BurnerPage extends StatefulWidget {
  const BurnerPage({super.key, required this.state});

  final AppState state;

  @override
  State<BurnerPage> createState() => _BurnerPageState();
}

class _BurnerPageState extends State<BurnerPage> {
  final _capPath = TextEditingController();
  final _instanceAid = TextEditingController();
  int _moduleIndex = 0;
  bool _defaultSelected = true;
  bool _deleteFirst = true;
  bool _force = false;
  bool _showKeys = false;

  @override
  void dispose() {
    _capPath.dispose();
    _instanceAid.dispose();
    super.dispose();
  }

  Future<void> _browseKeys() async {
    final path = await pickFile(
      title: 'Choose a config.ini with the three keys',
      filter: 'Config files (*.ini)|*.ini|All files (*.*)|*.*',
      startIn: widget.state.gpKeyFile.contains(r'\') ? widget.state.gpKeyFile.substring(0, widget.state.gpKeyFile.lastIndexOf(r'\')) : null,
    );
    if (path == null || !mounted) return;
    await widget.state.gpReadKeyFile(path);
  }

  /// One key box: 16 bytes of hex, hidden until the eye is clicked, and checked as it is typed.
  Widget _keyBox(AppState state, String label, TextEditingController controller) {
    final bytes = controller.text.replaceAll(RegExp('[^0-9a-fA-F]'), '').length ~/ 2;
    final ok = bytes == 16;
    return TextField(
      controller: controller,
      enabled: !state.busy,
      obscureText: !_showKeys,
      obscuringCharacter: '*',
      style: mono(size: 12.5),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F ]')), UpperCaseText()],
      decoration: InputDecoration(
        labelText: label,
        helperText: controller.text.isEmpty ? '16 bytes of hex' : '$bytes of 16 bytes',
        helperStyle: TextStyle(fontSize: 11, color: controller.text.isEmpty || ok ? subtleText(context) : warnColor),
        isDense: true,
        suffixIcon: controller.text.isEmpty
            ? null
            : Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded, size: 17, color: ok ? okColor : warnColor),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onChanged: (_) {
        setState(() {}); // the byte count and the tick follow what is typed
        state.gpApplyKeys();
      },
    );
  }

  Future<void> _browseCap() async {
    final path = await pickFile(title: 'Choose a CAP file', filter: 'Java Card packages (*.cap)|*.cap|All files (*.*)|*.*');
    if (path == null || !mounted) return;
    await _openCap(path);
  }

  Future<void> _openCap(String path) async {
    _capPath.text = path;
    await widget.state.gpOpenCap(path);
    final cap = widget.state.gpCap;
    if (!mounted || cap == null) return;
    setState(() {
      _moduleIndex = 0;
      _capPath.text = widget.state.gpCapPath; // without the quotes a pasted path may have
      // the instance AID is normally the applet's own AID, which is what the test card uses
      _instanceAid.text = cap.appletAids.isEmpty ? '' : Hex.of(cap.appletAids.first);
    });
  }

  Future<bool> _confirm(String title, String question, String action, {bool danger = true}) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(danger ? Icons.warning_amber_rounded : Icons.help_outline_rounded, color: danger ? failColor : null, size: 40),
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

  Future<void> _delete(GpEntry entry) async {
    final isPackage = entry.kind == GpKind.package;
    // the card does not say which package an applet came from, so only the ones under an AID the package defines can
    // be named; an instance under any other AID goes as well
    final named = (widget.state.gpContents?.applications ?? const <GpEntry>[])
        .where((a) => entry.modules.any((m) => Hex.same(m, a.aid)))
        .map((a) => Hex.of(a.aid));
    final withIt = isPackage
        ? '\n\nEvery applet installed from it goes too, with its data${named.isEmpty ? '.' : ':\n${named.join('\n')}'}'
        : '';
    final ok = await _confirm(
      isPackage ? 'Delete this package?' : 'Delete this applet?',
      'This removes ${Hex.of(entry.aid)} from the card for good. The data an applet kept is lost with it, and the only '
          'way back is loading the package again.$withIt',
      'Delete it',
    );
    if (ok) await widget.state.gpDelete(entry.aid);
  }

  Future<void> _burn() async {
    final state = widget.state;
    final cap = state.gpCap;
    if (cap == null) return;
    final Uint8List instance;
    try {
      instance = Hex.parse(_instanceAid.text);
    } on FormatException catch (e) {
      state.snack(e.message, error: true);
      return;
    }
    if (instance.length < 5 || instance.length > 16) {
      state.snack('An applet AID is 5 to 16 bytes; this one is ${instance.length}.', error: true);
      return;
    }
    final module = cap.appletAids[_moduleIndex.clamp(0, cap.appletAids.length - 1)];
    final already = state.gpContents?.package(cap.packageAid) != null;
    // what the card would refuse is said now, not after the confirmation — unless Force, which clears the way instead
    final problem = _force
        ? null
        : state.gpContents?.loadProblem(cap.packageAid, instanceAid: instance, defaultSelected: _defaultSelected, deleteFirst: _deleteFirst);
    if (problem != null) {
      state.snack(problem, error: true);
      return;
    }
    final blockers = _force
        ? (state.gpContents?.blockers(cap.packageAid, instanceAid: instance, defaultSelected: _defaultSelected) ?? const [])
        : const [];
    final ok = await _confirm(
      'Load ${cap.name} onto the card?',
      'Package ${Hex.of(cap.packageAid)} will be written to the card and installed as ${Hex.of(instance)}'
          '${_defaultSelected ? ', as the default applet' : ''}.'
          '${_force && blockers.isNotEmpty ? '\n\nForce: ${blockers.map((b) => Hex.of(b.$1)).join(', ')} already on the card '
              '${blockers.length == 1 ? 'is' : 'are'} deleted first, with ${blockers.length == 1 ? 'its' : 'their'} data.' : ''}'
          '${!_force && already && _deleteFirst ? '\n\nThe package with that AID is already on the card, so it is deleted first, '
              'together with its applets and their data.' : ''}'
          '\n\nDo not take the card off the reader while this runs.',
      'Load it',
    );
    if (!ok) return;
    await state.gpLoadCap(
      instanceAid: instance,
      moduleAid: module,
      defaultSelected: _defaultSelected,
      deleteFirst: _deleteFirst,
      force: _force,
    );
  }

  /// The settings the two burn buttons share, or null with a message when they are not usable.
  (Uint8List, Uint8List)? _settings() {
    final state = widget.state;
    final cap = state.gpCap;
    if (cap == null) return null;
    final Uint8List instance;
    try {
      instance = Hex.parse(_instanceAid.text);
    } on FormatException catch (e) {
      state.snack(e.message, error: true);
      return null;
    }
    if (instance.length < 5 || instance.length > 16) {
      state.snack('An applet AID is 5 to 16 bytes; this one is ${instance.length}.', error: true);
      return null;
    }
    return (instance, cap.appletAids[_moduleIndex.clamp(0, cap.appletAids.length - 1)]);
  }

  Future<void> _autoBurn() async {
    final state = widget.state;
    final cap = state.gpCap;
    final s = _settings();
    if (cap == null || s == null) return;
    final (instance, module) = s;
    final ok = await _confirm(
      'Burn ${cap.name} onto one card after another?',
      'Every card put on the reader gets package ${Hex.of(cap.packageAid)}, installed as ${Hex.of(instance)}'
          '${_defaultSelected ? ', as the default applet' : ''}'
          '${_force ? ', and any applet already using that AID is deleted first (Force), with its data' : _deleteFirst ? ', and a package already there is deleted first with its data' : ''}.\n\n'
          'Press once: after that put a card on, wait for "OK finished for 1", take it off, and put the next one on. '
          'The run keeps going until you press "Stop auto load" — it does not stop by itself, even if some cards fail.',
      'Start auto load',
    );
    if (!ok || !mounted) return;
    await state.startAutoBurn(
      instanceAid: instance,
      moduleAid: module,
      defaultSelected: _defaultSelected,
      deleteFirst: _deleteFirst,
      force: _force,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final batch = state.batch;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _channelPanel(context, state),
      const SizedBox(height: 12),
      if (batch != null) ...[
        _BatchPanel(state: state),
        const SizedBox(height: 12),
      ],
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: _contentsPanel(context, state)),
          const SizedBox(width: 12),
          SizedBox(width: 430, child: _capPanel(context, state)),
        ]),
      ),
    ]);
  }

  // ------------------------------------------------------------------ the secure channel

  Widget _channelPanel(BuildContext context, AppState state) {
    final keys = state.gpKeys;
    final open = state.gpOpen;
    final info = state.gpManager?.initializeUpdate;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.vpn_key_rounded, size: 20, color: open ? okColor : Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          const Text('Card manager keys', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(width: 12),
          StatusChip(open ? 'OK' : 'INFO'),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              open
                  ? 'Secure channel open  ·  SCP${h2(info!.scpId)}, key version ${info.keyVersion}, counter ${info.sequenceCounter}'
                  : (keys == null ? 'No keys yet' : 'Keys ready: ${keys.masked}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: open ? okColor : subtleText(context)),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _keyBox(state, 'Key-ENC (auth)', state.gpEncController)),
          const SizedBox(width: 8),
          Expanded(child: _keyBox(state, 'Key-MAC', state.gpMacController)),
          const SizedBox(width: 8),
          Expanded(child: _keyBox(state, 'Key-DEK', state.gpDekController)),
          const SizedBox(width: 6),
          IconButton(
            tooltip: _showKeys ? 'Hide the keys' : 'Show the keys',
            onPressed: () => setState(() => _showKeys = !_showKeys),
            icon: Icon(_showKeys ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 92,
            child: DropdownButtonFormField<int>(
              initialValue: state.gpKeyVersion,
              isDense: true,
              decoration: InputDecoration(
                labelText: 'Key ver.',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              items: [for (final v in [0, 1, 2, 3, 0x20, 0x21, 0x30]) DropdownMenuItem(value: v, child: Text(v == 0 ? 'any' : '$v'))],
              onChanged: state.busy ? null : (v) => state.gpSetKeyVersion(v ?? 0),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 46,
            child: FilledButton.icon(
              onPressed: state.canRun && keys != null && !open ? state.gpAuthenticate : null,
              icon: const Icon(Icons.lock_open_rounded, size: 18),
              label: const Text('Open channel', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Tooltip(
            message: 'Keep these three keys in the tool, so they do not have to be typed again',
            child: FilledButton.tonalIcon(
              onPressed: state.busy || keys == null ? null : state.gpSaveKeys,
              icon: const Icon(Icons.save_outlined, size: 17),
              label: const Text('Save keys'),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Take the three keys out of a PyApduTool config.ini. Nothing else in that file is used.',
            child: OutlinedButton.icon(
              onPressed: state.busy ? null : _browseKeys,
              icon: const Icon(Icons.folder_open_rounded, size: 17),
              label: const Text('From a config.ini'),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'The test card\'s three keys, from PyApduTool\'s config.ini. The simulated card holds the same keys, '
                'so they open it too.',
            child: OutlinedButton(onPressed: state.busy ? null : state.gpUseTestKey, child: const Text('Default test key')),
          ),
          const SizedBox(width: 12),
          if (state.gpKeyProblem != null)
            Flexible(
              child: Text(state.gpKeyProblem!,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: warnColor)),
            )
          else if (state.gpKeySource.isNotEmpty)
            Flexible(
              child: Text('From ${state.gpKeySource}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: subtleText(context))),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.shield_outlined, size: 15, color: warnColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Only these three keys are needed: nothing else of a card manager\'s setup comes from a file. They never go '
              'to the card and are never written to a report, a log or the APDU list, because only cryptograms travel. '
              'A wrong key set is refused by the card, so check the keys and the key version before opening the channel.',
              style: TextStyle(fontSize: 11.5, color: subtleText(context), height: 1.35),
            ),
          ),
        ]),
        if (state.gpError != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: failColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
            child: Text(state.gpError!, style: const TextStyle(fontSize: 12.5, color: failColor)),
          ),
        ],
      ]),
    );
  }

  // ------------------------------------------------------------------ what is on the card

  Widget _contentsPanel(BuildContext context, AppState state) {
    final c = state.gpContents;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PanelHeader(
          icon: Icons.inventory_2_outlined,
          title: 'On the card',
          trailing: TextButton.icon(
            onPressed: state.canRun && state.gpOpen ? state.gpReadCard : null,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Refresh'),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: c == null
              ? EmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: state.connected ? 'Nothing read yet' : 'Connect first',
                  text: state.connected
                      ? 'Type the card\'s three keys, or take them from a config.ini, then click "Open channel". The '
                          'card then lists its packages, the applets installed from them, and the card manager itself.'
                      : 'Put the card on the reader, choose the reader at the top and click Connect.',
                )
              : ListView(children: [
                  _group(context, 'Packages (${c.packages.length})', Icons.folder_zip_outlined,
                      'Loaded code. Deleting one takes the applets made from it, and their data, with it.'),
                  for (final p in c.packages) _entryTile(context, state, p),
                  if (c.packages.isEmpty) _none(context, 'No package on the card.'),
                  const SizedBox(height: 10),
                  _group(context, 'Applets (${c.applications.length})', Icons.widgets_outlined,
                      'Installed instances. These are the AIDs a phone app can select.'),
                  for (final a in c.applications) _entryTile(context, state, a),
                  if (c.applications.isEmpty) _none(context, 'No applet installed.'),
                  const SizedBox(height: 10),
                  _group(context, 'Card manager', Icons.admin_panel_settings_outlined, 'The security domain this channel is open with.'),
                  for (final i in c.isd) _entryTile(context, state, i),
                ]),
        ),
      ]),
    );
  }

  Widget _group(BuildContext context, String title, IconData icon, String note) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Theme.of(context).colorScheme.primary)),
              Text(note, style: TextStyle(fontSize: 11.5, color: subtleText(context))),
            ]),
          ),
        ]),
      );

  Widget _none(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(left: 24, bottom: 6),
        child: Text(text, style: TextStyle(fontSize: 12.5, color: subtleText(context), fontStyle: FontStyle.italic)),
      );

  Widget _entryTile(BuildContext context, AppState state, GpEntry e) {
    final canDelete = e.kind != GpKind.securityDomain;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        color: isDark(context) ? Colors.white.withValues(alpha: 0.03) : const Color(0xFFF7F8FC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor(context)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: SelectableText(e.aidText, style: mono(size: 13, weight: FontWeight.w700))),
              if (e.asText.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text('"${e.asText}"', style: TextStyle(fontSize: 12, color: subtleText(context))),
              ],
            ]),
            const SizedBox(height: 3),
            Wrap(spacing: 6, runSpacing: 4, children: [
              _tag(context, e.lifeCycleText, e.lifeCycle == 0x07 || e.lifeCycle == 0x0F || e.lifeCycle == 0x01 ? okColor : warnColor),
              for (final p in e.privilegeNames) _tag(context, p, p == 'Default selected' ? nfcColor : blockedColor),
              for (final m in e.modules) _tag(context, 'applet ${Hex.of(m)}', subtleText(context)),
            ]),
          ]),
        ),
        if (e.kind == GpKind.application)
          IconButton(
            tooltip: 'SELECT this AID, the way an app does. It closes the card manager channel.',
            onPressed: state.canRun ? () => state.gpSelect(e.aid) : null,
            icon: const Icon(Icons.play_circle_outline_rounded, size: 20),
          ),
        if (canDelete)
          IconButton(
            tooltip: 'Delete it from the card',
            onPressed: state.canRun && state.gpOpen ? () => _delete(e) : null,
            icon: Icon(Icons.delete_outline_rounded, size: 20, color: state.canRun && state.gpOpen ? failColor : null),
          ),
      ]),
    );
  }

  Widget _tag(BuildContext context, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      );

  // ------------------------------------------------------------------ loading a CAP file

  Widget _capPanel(BuildContext context, AppState state) {
    final cap = state.gpCap;
    final loading = state.busy && state.gpLoadTotal > 0 && state.gpLoadDone < state.gpLoadTotal;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PanelHeader(icon: Icons.local_fire_department_outlined, title: 'Burn a CAP file'),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _capPath,
                    enabled: !state.busy,
                    style: mono(size: 12),
                    decoration: InputDecoration(
                      labelText: 'CAP file',
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onSubmitted: state.busy ? null : _openCap,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: state.busy ? null : _browseCap, child: const Text('Browse')),
              ]),
              if (cap != null) ...[
                const SizedBox(height: 12),
                _kv(context, 'Package AID', Hex.of(cap.packageAid), hex: true),
                _kv(context, 'Version', cap.packageVersion),
                _kv(context, 'Size', '${cap.componentBytes} bytes in ${cap.loadBlocks().length} blocks'),
                _kv(context, 'Components', cap.componentNames.join(', ')),
                const SizedBox(height: 10),
                if (cap.appletAids.length > 1)
                  DropdownButtonFormField<int>(
                    initialValue: _moduleIndex,
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: 'Applet in the package',
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    items: [
                      for (var i = 0; i < cap.appletAids.length; i++)
                        DropdownMenuItem(value: i, child: Text(Hex.of(cap.appletAids[i]), style: mono(size: 12))),
                    ],
                    onChanged: state.busy ? null : (v) => setState(() => _moduleIndex = v ?? 0),
                  )
                else if (cap.appletAids.isNotEmpty)
                  _kv(context, 'Applet in the package', Hex.of(cap.appletAids.first), hex: true),
                const SizedBox(height: 10),
                TextField(
                  controller: _instanceAid,
                  enabled: !state.busy,
                  style: mono(size: 12.5),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F ]')), UpperCaseText()],
                  decoration: InputDecoration(
                    labelText: 'Install as (instance AID)',
                    helperText: 'What a phone app will SELECT. Usually the applet AID itself.',
                    helperMaxLines: 2,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 6),
                _checkRow(
                  context,
                  value: _defaultSelected,
                  onChanged: state.busy ? null : (v) => setState(() => _defaultSelected = v),
                  title: 'Default selected',
                  subtitle: 'The card picks this applet after every power-up, as your test card does.',
                ),
                _checkRow(
                  context,
                  value: _deleteFirst,
                  onChanged: state.busy || _force ? null : (v) => setState(() => _deleteFirst = v),
                  title: 'Delete the package first if it is there',
                  subtitle: 'A card refuses a package whose AID it already has. Its data is lost.',
                ),
                _checkRow(
                  context,
                  value: _force,
                  onChanged: state.busy ? null : (v) => setState(() => _force = v),
                  title: 'Force: delete any applet already using this AID first',
                  subtitle: 'For a card that was burned before: removes the applet at this AID (and any default-selected '
                      'applet), then installs the new one. Their data is lost.',
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 46,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: failColor),
                    onPressed: state.canRun && state.gpOpen && cap.appletAids.isNotEmpty ? _burn : null,
                    icon: const Icon(Icons.local_fire_department_rounded),
                    label: const Text('Load and install', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
                if (!state.gpOpen && !state.batchRunning)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Open the secure channel first.', style: TextStyle(fontSize: 12, color: warnColor)),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 46,
                  child: state.batchRunning
                      ? FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: warnColor),
                          onPressed: state.stopAutoBurn,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('Stop auto load', style: TextStyle(fontWeight: FontWeight.w700)),
                        )
                      : Tooltip(
                          message: 'Burn this CAP onto one card after another. Press once, then only swap the cards.',
                          child: FilledButton.icon(
                            onPressed: state.canRun && cap.appletAids.isNotEmpty && state.gpKeys != null ? _autoBurn : null,
                            icon: const Icon(Icons.all_inclusive_rounded),
                            label: const Text('Auto load', style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Auto load needs the keys and this CAP, not an open channel: it opens one for every card by itself.',
                    style: TextStyle(fontSize: 11.5, color: subtleText(context), height: 1.3),
                  ),
                ),
                if (loading || state.gpLoadTotal > 0) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: LinearProgressIndicator(
                      value: state.gpLoadTotal == 0 ? 0 : state.gpLoadDone / state.gpLoadTotal,
                      minHeight: 8,
                      backgroundColor: borderColor(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('Block ${state.gpLoadDone} of ${state.gpLoadTotal}',
                      style: TextStyle(fontSize: 11.5, color: subtleText(context))),
                ],
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    'Choose the .cap file your build makes. The screen then shows the package AID, the applets in it '
                    'and how many blocks it takes, before anything is sent to the card.',
                    style: TextStyle(fontSize: 12.5, color: subtleText(context), height: 1.4),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }

  /// A checkbox with a title and a line under it. A ListTile would paint its ink on the panel behind it, so this
  /// keeps the plain widgets.
  Widget _checkRow(BuildContext context,
          {required bool value, required void Function(bool)? onChanged, required String title, required String subtitle}) =>
      InkWell(
        onTap: onChanged == null ? null : () => onChanged(!value),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 34,
              height: 34,
              child: Checkbox(value: value, onChanged: onChanged == null ? null : (v) => onChanged(v ?? false)),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 13)),
                  Text(subtitle, style: TextStyle(fontSize: 11.5, color: subtleText(context), height: 1.3)),
                ]),
              ),
            ),
          ]),
        ),
      );

  Widget _kv(BuildContext context, String k, String v, {bool hex = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 118, child: Text(k, style: TextStyle(fontSize: 12, color: subtleText(context)))),
          Expanded(child: SelectableText(v, style: hex ? mono(size: 12.5) : const TextStyle(fontSize: 12.5))),
        ]),
      );
}

/// The auto load panel: what it is waiting for, how many cards are done, and a line per card.
class _BatchPanel extends StatelessWidget {
  const _BatchPanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final batch = state.batch!;
    final running = batch.running;
    final colour = switch (batch.stage) {
      BatchStage.burning => failColor,
      BatchStage.waitingForCard => nfcColor,
      BatchStage.waitingForRemoval => okColor,
      BatchStage.idle => subtleText(context),
    };
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (running)
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4, color: colour))
          else
            Icon(Icons.all_inclusive_rounded, size: 19, color: colour),
          const SizedBox(width: 10),
          const Text('Auto load', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              running
                  ? '${batch.stage.label}${batch.stage == BatchStage.burning ? ' card ${batch.done + 1}' : ''}'
                  : 'Finished: ${batch.ok} burned, ${batch.failed} failed'
                      '${batch.stopped == null ? '' : '  ·  ${batch.stopped}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: colour, fontWeight: FontWeight.w700),
            ),
          ),
          _count(context, '${batch.ok}', 'burned', okColor),
          const SizedBox(width: 8),
          _count(context, '${batch.failed}', 'failed', batch.failed == 0 ? subtleText(context) : failColor),
          if (state.batchReportPath != null) ...[
            const SizedBox(width: 10),
            Tooltip(
              message: 'The report of this run: every card with its card ID',
              child: FilledButton.tonalIcon(
                onPressed: state.busy ? null : state.openBatchReport,
                icon: const Icon(Icons.description_outlined, size: 17),
                label: const Text('Open report'),
              ),
            ),
          ],
        ]),
        if (batch.cards.isNotEmpty) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 104),
            child: Scrollbar(
              child: ListView(
                reverse: true, // the newest card is the one you want to see
                padding: EdgeInsets.zero,
                children: [
                  for (final c in batch.cards.reversed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(children: [
                        Icon(c.ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                            size: 14, color: c.ok ? okColor : failColor),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(c.line,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: mono(size: 12, color: c.ok ? okColor : failColor)),
                        ),
                      ]),
                    ),
                ],
              ),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _count(BuildContext context, String value, String what, Color colour) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: colour.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(9)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: colour)),
          const SizedBox(width: 5),
          Text(what, style: TextStyle(fontSize: 11.5, color: colour)),
        ]),
      );
}
