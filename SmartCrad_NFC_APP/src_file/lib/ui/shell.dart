import 'package:flutter/material.dart';

import '../card/simulated_card.dart';
import '../core/atr_info.dart';
import '../core/hex.dart';
import '../core/platform.dart';
import '../core/session.dart';
import '../state/app_state.dart';
import 'pages/applet_log_page.dart';
import 'pages/bootloader_page.dart';
import 'pages/burner_page.dart';
import 'pages/card_profiles_page.dart';
import 'pages/check_page.dart';
import 'pages/company_id_page.dart';
import 'pages/console_page.dart';
import 'pages/error_map_page.dart';
import 'pages/home_page.dart';
import 'pages/log_page.dart';
import 'pages/read_page.dart';
import 'log_dock.dart';
import 'pages/rules_page.dart';
import 'pages/run_all_page.dart';
import 'pages/test_page.dart';
import 'theme.dart';
import 'widgets.dart';

class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.state});

  final AppState state;

  List<(String, String, IconData, IconData)> _pages(PhonePlatform p) => [
        ('Home', 'Everything this app can do: pick one to open it', Icons.home_rounded, Icons.home_rounded),
        ('${p.short} check', 'One click: will an ${p.app} find this card and use the applet?', Icons.phone_iphone_outlined,
            Icons.phone_iphone_rounded),
        ('APDU console', 'Type one command in hex and send it the way an ${p.app} sends it', Icons.terminal_outlined,
            Icons.terminal_rounded),
        ('Read & write card', 'Read the whole card, or write bytes into it and check them by reading back',
            Icons.import_export_outlined, Icons.import_export_rounded),
        ('Card Unit Test', 'The card_test.ps1 checks, extra checks and the card size, run as an ${p.app}',
            Icons.fact_check_outlined, Icons.fact_check_rounded),
        ('Run all tests', 'Every test on both phones, the production checks, and one final report',
            Icons.rocket_launch_outlined, Icons.rocket_launch_rounded),
        ('Burner', 'Load a CAP file, and read, select or delete the packages and applets on the card',
            Icons.local_fire_department_outlined, Icons.local_fire_department_rounded),
        ('Log', 'Every APDU with its answer and time', Icons.receipt_long_outlined, Icons.receipt_long_rounded),
        ('Rules', 'What the tool applies for iPhone and Android, and where each rule comes from', Icons.gavel_outlined,
            Icons.gavel_rounded),
        ('Error map', "Every status word, the check that sends it, what the meter should do, and the old applet's answer",
            Icons.rule_outlined, Icons.rule_rounded),
        ('Card profiles', 'Which card Read, Write and Block editor talk to — EMG and any you add',
            Icons.sim_card_outlined, Icons.sim_card_rounded),
        ('Make firmware card', 'Give a meter firmware .bin and make the set of cards that flash it',
            Icons.developer_board_outlined, Icons.developer_board_rounded),
        ('Read Company ID', 'Read the card\'s company and identity block — the fields the utility\'s Read Company ID shows',
            Icons.badge_outlined, Icons.badge_rounded),
        ('Applet log', 'Read the applet\'s own command log — what a phone actually sent the card',
            Icons.bug_report_outlined, Icons.bug_report_rounded),
      ];

  @override
  Widget build(BuildContext context) {
    final dark = isDark(context);
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: dark
              ? const LinearGradient(
                  colors: [Color(0xFF0A0F1E), Color(0xFF0E1630), Color(0xFF0A0F1E)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : const LinearGradient(
                  colors: [Color(0xFFF3F5FA), Color(0xFFE9EEFB), Color(0xFFF3F5FA)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
        ),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final pages = _pages(state.platform);
            return Row(children: [
              Expanded(
                child: Column(children: [
                  _TopBar(state: state, title: pages[state.page].$1, subtitle: pages[state.page].$2),
                  _ConnectionBar(state: state),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      child: FadeIndexedStack(index: state.page, children: [
                        HomePage(state: state),
                        CheckPage(state: state),
                        ConsolePage(state: state),
                        ReadPage(state: state),
                        TestPage(state: state),
                        RunAllPage(state: state),
                        BurnerPage(state: state),
                        LogPage(state: state),
                        const RulesPage(),
                        ErrorMapPage(state: state),
                        CardProfilesPage(state: state),
                        BootloaderPage(state: state),
                        CompanyIdPage(state: state),
                        AppletLogPage(state: state),
                      ]),
                    ),
                  ),
                  LogDock(state: state),
                  _StatusBar(state: state),
                ]),
              ),
            ]);
          },
        ),
      ),
    );
  }

}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.state, required this.title, required this.subtitle});

  final AppState state;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final home = state.page == Pages.home;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      child: Row(children: [
        // the only way back now that there is no side column, so it is always here and never hidden
        Tooltip(
          message: home ? 'You are on the home screen' : 'Back to all features',
          child: SizedBox(
            height: 44,
            child: FilledButton.tonalIcon(
              onPressed: home ? null : () => state.setPage(Pages.home),
              icon: const Icon(Icons.home_rounded, size: 19),
              label: const Text('Home', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Column(
              key: ValueKey(title),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: subtleText(context), fontSize: 13)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        Tooltip(
          message: 'Which phone the tool acts as. Each phone has its own NFC rules.',
          child: SegmentedButton<PhonePlatform>(
            segments: const [
              ButtonSegment(value: PhonePlatform.iphone, label: Text('iPhone'), icon: Icon(Icons.phone_iphone_rounded)),
              ButtonSegment(value: PhonePlatform.android, label: Text('Android'), icon: Icon(Icons.smartphone_rounded)),
            ],
            selected: {state.platform},
            showSelectedIcon: false,
            onSelectionChanged: state.busy ? null : (s) => state.setPlatform(s.first),
          ),
        ),
        const SizedBox(width: 10),
        ValueListenableBuilder<ThemeMode>(
          valueListenable: state.themeMode,
          builder: (context, mode, _) => IconButton.filledTonal(
            tooltip: mode == ThemeMode.dark ? 'Light theme' : 'Dark theme',
            onPressed: state.toggleTheme,
            icon: Icon(mode == ThemeMode.dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded, size: 20),
          ),
        ),
      ]),
    );
  }
}

/// The first row of controls: Connect and Disconnect, the reader, the card, and the iPhone app's AID list.
class _ConnectionBar extends StatelessWidget {
  const _ConnectionBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final keys = [...state.readers, SimulatedCard.key];
    final ios = state.platform == PhonePlatform.iphone;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Panel(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          // 1. Connect / Disconnect
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              onPressed: state.connected || state.busy || state.connecting ? null : state.connect,
              style: FilledButton.styleFrom(
                // when connected the button is disabled; keep it green so the state is easy to see
                disabledBackgroundColor: state.connected ? okColor.withValues(alpha: 0.22) : null,
                disabledForegroundColor: state.connected ? okColor : null,
              ),
              icon: state.connecting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : Icon(state.connected ? Icons.link_rounded : Icons.power_settings_new_rounded),
              label: Text(state.connected ? 'Connected' : 'Connect', style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 44,
            child: OutlinedButton.icon(
              onPressed: state.connected && !state.busy ? state.disconnect : null,
              icon: const Icon(Icons.link_off_rounded),
              label: const Text('Disconnect'),
            ),
          ),
          const SizedBox(width: 14),
          // 2. reader
          Icon(state.usingSimulator ? Icons.memory_rounded : Icons.contactless_rounded,
              size: 20, color: state.usingSimulator ? warnColor : Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: keys.contains(state.selected) ? state.selected : null,
                isExpanded: true,
                hint: const Text('Choose a reader'),
                borderRadius: BorderRadius.circular(14),
                items: [
                  for (final k in keys)
                    DropdownMenuItem(
                      value: k,
                      child: Row(children: [
                        Icon(
                          k == SimulatedCard.key
                              ? Icons.memory_rounded
                              : (AtrInfo.looksContactless(k) ? Icons.contactless_rounded : Icons.credit_card_rounded),
                          size: 18,
                          color: subtleText(context),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(k, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                      ]),
                    ),
                ],
                onChanged: state.busy || state.connected ? null : (v) => v == null ? null : state.selectReader(v),
              ),
            ),
          ),
          IconButton(
            tooltip: state.connected ? 'Disconnect first to look for readers' : 'Look for readers again',
            onPressed: state.busy || state.connected ? null : state.refreshReaders,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
          const SizedBox(width: 6),
          // 3. card status
          Expanded(flex: 4, child: _CardStatus(state: state)),
          const SizedBox(width: 12),
          // 4. AID list (iPhone only)
          SizedBox(
            width: 230,
            child: Tooltip(
              message: ios
                  ? 'The first AID is the applet every screen selects. The whole list is what an iPhone app would put '
                      'in its Info.plist, in order; separate them with commas.\n\n'
                      'Burning an applet puts its AID here by itself.'
                  : 'The applet every screen selects. Android needs no AID list of its own, but the tool still has to '
                      'know which applet to talk to.\n\nBurning an applet puts its AID here by itself.',
              child: TextField(
                controller: state.aidController,
                enabled: !state.busy,
                style: mono(size: 13),
                decoration: InputDecoration(
                  labelText: ios ? 'Applet AID  ·  iPhone app list' : 'Applet AID',
                  prefixIcon: const Icon(Icons.list_alt_rounded, size: 20),
                  isDense: true,
                  filled: true,
                  fillColor: panelColor(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: borderColor(context))),
                  enabledBorder:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: borderColor(context))),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _CardStatus extends StatelessWidget {
  const _CardStatus({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final connected = state.connected;
    final color = connected ? okColor : (state.lastError != null && !connected ? failColor : subtleText(context));
    final info = state.cardInfo;
    final line1 = connected
        ? (state.usingSimulator ? 'Connected to the simulator' : 'Connected, exclusive')
        : (state.connecting ? 'Connecting...' : 'Not connected');
    final line2 = connected
        ? '${info != null && info.isoDep ? 'ISO-DEP card' : 'card'} · ATR ${state.cardAtr == null ? '-' : Hex.compact(state.cardAtr)}'
            '${state.cardUid == null ? '' : ' · UID ${Hex.compact(state.cardUid)}'}'
        : 'Click Connect to open the reader and power the card';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(line1, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: color)),
            Tooltip(
              message: line2,
              child: Text(line2, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 11.5, color: subtleText(context))),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.session;
    final live = s != null && s.active && s.detected && state.connected;
    final ios = state.platform == PhonePlatform.iphone;
    final fraction = live && ios ? (s.elapsed / PhoneSession.iosLimitSeconds).clamp(0.0, 1.0) : 0.0;
    final barColor = fraction > 0.8 ? failColor : (fraction > 0.5 ? warnColor : nfcColor);
    final sessionText = !live
        ? (state.connected ? 'No phone session. The next command taps the card first.' : 'Not connected.')
        : (ios
            ? 'iPhone session ${s.elapsed.toStringAsFixed(1)} s of ${PhoneSession.iosLimitSeconds} s   ·   ${s.initialSelectedAid}'
            : 'Android session ${s.elapsed.toStringAsFixed(1)} s (no limit)   ·   IsoDep');
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: panelColor(context).withValues(alpha: 0.85),
        border: Border(top: BorderSide(color: borderColor(context))),
      ),
      child: Row(children: [
        if (state.busy)
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Container(
              width: 9, height: 9, decoration: BoxDecoration(color: state.connected ? okColor : subtleText(context), shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Text(state.busy ? '${state.busyTitle}...' : (state.connected ? 'Ready' : 'Not connected'),
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '${state.platform.short} rules · ${state.usingSimulator ? 'Simulator' : 'Reader: ${state.selected ?? '-'}'}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: subtleText(context)),
          ),
        ),
        Icon(Icons.nfc_rounded, size: 16, color: live ? barColor : subtleText(context)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(sessionText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: subtleText(context))),
        ),
        if (live && ios) ...[
          const SizedBox(width: 10),
          SizedBox(
            width: 110,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: fraction, minHeight: 6, color: barColor, backgroundColor: borderColor(context)),
            ),
          ),
        ],
      ]),
    );
  }
}
