import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/guide.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets.dart';

/// The first screen: one tile per thing the app does, and pressing a tile opens it. This is how you get around, so
/// every other page has a tile here.
///
/// The long guide text is not on this screen on purpose. It lives in the web page the "Full guide" button writes.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  static IconData iconFor(String name) => switch (name) {
        'info' => Icons.info_outline_rounded,
        'play' => Icons.play_circle_outline_rounded,
        'phone' => Icons.phone_iphone_rounded,
        'check' => Icons.verified_outlined,
        'terminal' => Icons.terminal_rounded,
        'download' => Icons.download_for_offline_outlined,
        'readwrite' => Icons.import_export_rounded,
        'tasks' => Icons.fact_check_outlined,
        'fire' => Icons.local_fire_department_rounded,
        'list' => Icons.receipt_long_outlined,
        'gavel' => Icons.gavel_rounded,
        'rule' => Icons.rule_rounded,
        'folder' => Icons.folder_open_rounded,
        'help' => Icons.help_outline_rounded,
        'android' => Icons.smartphone_rounded,
        'chip' => Icons.memory_rounded,
        'report' => Icons.description_outlined,
        'rocket' => Icons.rocket_launch_rounded,
        'simcard' => Icons.sim_card_rounded,
        'bootloader' => Icons.developer_board_rounded,
        'badge' => Icons.badge_rounded,
        'applog' => Icons.bug_report_rounded,
        _ => Icons.article_outlined,
      };

  /// Each feature has its own colour, so a tile is recognisable before the title is read.
  static Color colorFor(String name) => switch (name) {
        'rocket' => const Color(0xFF7C5CFF),
        'phone' => const Color(0xFF3B82F6),
        'android' => const Color(0xFF22C55E),
        'terminal' => const Color(0xFF06B6D4),
        'download' || 'readwrite' => const Color(0xFF14B8A6),
        'tasks' => const Color(0xFF0EA5E9),
        'fire' => const Color(0xFFF97316),
        'rule' => const Color(0xFFF59E0B),
        'list' => const Color(0xFF6366F1),
        'gavel' => const Color(0xFFA855F7),
        'report' => const Color(0xFFEC4899),
        'simcard' => const Color(0xFF8B5CF6),
        'bootloader' => const Color(0xFF0D9488),
        'badge' => const Color(0xFF10B981),
        'applog' => const Color(0xFFEF4444),
        _ => const Color(0xFF94A3B8),
      };

  @override
  Widget build(BuildContext context) {
    final tiles = guideFeatures.where((f) => f.onHome).toList();
    return ListView(padding: const EdgeInsets.only(bottom: 10), children: [
      _Hero(state: state),
      const SizedBox(height: 16),
      Row(children: [
        Icon(Icons.auto_awesome_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        const Text('What it can do', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(width: 10),
        Text('press one to open it', style: TextStyle(fontSize: 12.5, color: subtleText(context))),
      ]),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, box) {
          final columns = (box.maxWidth / 300).floor().clamp(1, 5);
          final width = (box.maxWidth - (columns - 1) * 14) / columns;
          return Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (var i = 0; i < tiles.length; i++)
                SizedBox(
                  width: width,
                  child: FadeSlideIn(
                    offset: 10 + (i % columns) * 2.0,
                    child: _FeatureTile(
                      feature: tiles[i],
                      onOpen: () {
                        if (tiles[i].platform != null) state.setPlatform(tiles[i].platform!);
                        state.setPage(tiles[i].page!);
                      },
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ]);
  }
}

/// The band at the top: what this is, whether the reader is ready, and the two things worth doing first.
class _Hero extends StatelessWidget {
  const _Hero({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final connected = state.connected;
    return Panel(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
      gradient: LinearGradient(
        colors: [
          const Color(0xFF7C5CFF).withValues(alpha: isDark(context) ? 0.28 : 0.16),
          const Color(0xFF22D3EE).withValues(alpha: isDark(context) ? 0.14 : 0.10),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: const LinearGradient(colors: [Color(0xFF5B7CFA), Color(0xFF22D3EE)]),
                boxShadow: [BoxShadow(color: seed.withValues(alpha: 0.45), blurRadius: 20, offset: const Offset(0, 8))],
              ),
              child: const Icon(Icons.contactless_rounded, color: Colors.white, size: 32),
            ),
            const SizedBox(height: 8),
            const Text('Prepaid Fw Team', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, height: 1.2)),
            const Text('1.0.0', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Color(0xFF7C5CFF), height: 1.25)),
          ],
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('NFC Card Tester', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, height: 1.1)),
            const SizedBox(height: 5),
            Text(
                'Talks to your contactless card the way a phone app does, and loads applets onto it like PyApduTool. '
                'Pick a tile below to begin.',
                style: TextStyle(fontSize: 13, color: subtleText(context), height: 1.45)),
            const SizedBox(height: 10),
            Row(children: [
              Icon(connected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  size: 16, color: connected ? okColor : warnColor),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  connected
                      ? 'Reader connected${state.usingSimulator ? ' (simulated card)' : ''}. Everything is ready.'
                      : 'Not connected yet. Put the card on the reader and click Connect at the top.',
                  maxLines: 2,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: connected ? okColor : warnColor),
                ),
              ),
            ]),
          ]),
        ),
        const SizedBox(width: 18),
        Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 196,
            height: 46,
            child: FilledButton.icon(
              onPressed: state.canRun ? () => state.setPage(Pages.runAll) : null,
              icon: const Icon(Icons.rocket_launch_rounded, size: 19),
              label: const Text('Run all tests', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(height: 9),
          SizedBox(
            width: 196,
            child: OutlinedButton.icon(
              onPressed: state.busy ? null : state.saveGuide,
              icon: const Icon(Icons.menu_book_rounded, size: 17),
              label: const Text('Full guide'),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// One tile: a drawn picture that matches the feature, its name, and one line about it. It lifts when the mouse is
/// over it, so it is clear the whole card is a button.
class _FeatureTile extends StatefulWidget {
  const _FeatureTile({required this.feature, required this.onOpen});

  final GuideFeature feature;
  final VoidCallback onOpen;

  @override
  State<_FeatureTile> createState() => _FeatureTileState();
}

class _FeatureTileState extends State<_FeatureTile> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final color = HomePage.colorFor(widget.feature.icon);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _over ? -3 : 0, 0),
          decoration: BoxDecoration(
            color: panelColor(context),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _over ? color.withValues(alpha: 0.65) : borderColor(context)),
            boxShadow: [
              BoxShadow(
                color: _over ? color.withValues(alpha: 0.28) : Colors.black.withValues(alpha: isDark(context) ? 0.25 : 0.05),
                blurRadius: _over ? 26 : 18,
                offset: Offset(0, _over ? 10 : 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              SizedBox(height: 96, child: _FeatureArt(icon: widget.feature.icon, color: color, lit: _over)),
              Padding(
                padding: const EdgeInsets.fromLTRB(15, 12, 13, 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(widget.feature.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
                    ),
                    AnimatedSlide(
                      duration: const Duration(milliseconds: 180),
                      offset: Offset(_over ? 0.22 : 0, 0),
                      child: Icon(Icons.arrow_forward_rounded, size: 17, color: color),
                    ),
                  ]),
                  const SizedBox(height: 5),
                  Text(widget.feature.what,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: subtleText(context), height: 1.4)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The picture at the top of a tile: a coloured field with soft shapes behind the feature's own symbol.
class _FeatureArt extends StatelessWidget {
  const _FeatureArt({required this.icon, required this.color, required this.lit});

  final String icon;
  final Color color;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final dark = isDark(context);
    // white reads well on the deep tints of the dark theme, but disappears on the pale ones of the light theme, so
    // there the symbol takes a deeper shade of the feature's own colour instead
    final symbol = dark ? Colors.white.withValues(alpha: 0.95) : Color.lerp(color, Colors.black, 0.30)!;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: lit ? 0.42 : 0.30),
            color.withValues(alpha: lit ? 0.18 : 0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: CustomPaint(
        painter: _ArtPainter(color: color, seedIcon: icon, dark: dark),
        child: Center(
          child: AnimatedScale(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            scale: lit ? 1.09 : 1,
            child: Icon(HomePage.iconFor(icon), size: 40, color: symbol),
          ),
        ),
      ),
    );
  }
}

/// Soft shapes behind the symbol. They are drawn rather than loaded, so they stay sharp at any size and follow the
/// theme; the arrangement comes from the feature's name, so every tile looks a little different.
class _ArtPainter extends CustomPainter {
  _ArtPainter({required this.color, required this.seedIcon, required this.dark});

  final Color color;
  final String seedIcon;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(seedIcon.codeUnits.fold<int>(0, (a, b) => a + b));
    // light shapes lift a dark tint; on a pale one they would vanish, so there the shapes are the colour itself
    final blob = Paint()..color = dark ? Colors.white.withValues(alpha: 0.07) : color.withValues(alpha: 0.13);
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        Offset(size.width * (0.12 + random.nextDouble() * 0.8), size.height * (0.1 + random.nextDouble() * 0.85)),
        14 + random.nextDouble() * 26,
        blob,
      );
    }
    // a soft band across the picture, so the symbol sits on something rather than floating
    final band = Paint()
      ..shader = LinearGradient(
        colors: [Colors.white.withValues(alpha: dark ? 0.10 : 0.26), Colors.white.withValues(alpha: 0.0)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.6));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height * 0.6), band);

    // a thin line at the bottom in the feature's colour, as a quiet underline
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - 3, size.width, 3),
      Paint()..color = color.withValues(alpha: 0.75),
    );
  }

  @override
  bool shouldRepaint(_ArtPainter old) => old.color != color || old.seedIcon != seedIcon || old.dark != dark;
}
