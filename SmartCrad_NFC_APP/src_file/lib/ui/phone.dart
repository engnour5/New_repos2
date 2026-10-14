import 'dart:math';

import 'package:flutter/material.dart';

import '../core/platform.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// A phone with the card. At a tap the card moves to the phone's NFC antenna (top of an iPhone, middle of the back of
/// an Android phone), NFC waves pulse while the phone talks to the card, and the screen shows the step and the result.
class PhoneMockup extends StatefulWidget {
  const PhoneMockup({
    super.key,
    required this.phase,
    required this.title,
    required this.detail,
    required this.busy,
    required this.platform,
  });

  final PhonePhase phase;
  final String title;
  final String detail;
  final bool busy;
  final PhonePlatform platform;

  @override
  State<PhoneMockup> createState() => _PhoneMockupState();
}

class _PhoneMockupState extends State<PhoneMockup> with SingleTickerProviderStateMixin {
  late final AnimationController _waves = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();

  bool get _ios => widget.platform == PhonePlatform.iphone;

  @override
  void dispose() {
    _waves.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phase = widget.phase;
    final accent = phaseColor(phase);
    final talking = widget.busy && (phase == PhonePhase.tapping || phase == PhonePhase.connected);
    final cardUp = talking || phase == PhonePhase.connected;
    const phoneW = 220.0, phoneH = 450.0;

    // where the card rests at a tap: the iPhone's antenna is at the top, an Android phone's in the middle of the back
    final double cardLeft = cardUp ? (_ios ? 128 : 150) : 136;
    final double cardTop = cardUp ? (_ios ? 26 : 200) : 352;

    return SizedBox(
      width: 300,
      height: 500,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: 40,
          top: 40,
          width: phoneW,
          height: phoneH - 40,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(60),
              boxShadow: [BoxShadow(color: accent.withValues(alpha: isDark(context) ? 0.35 : 0.25), blurRadius: 70, spreadRadius: 4)],
            ),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 750),
          curve: Curves.easeOutBack,
          left: cardLeft,
          top: cardTop,
          child: AnimatedRotation(
            duration: const Duration(milliseconds: 750),
            curve: Curves.easeOutBack,
            turns: cardUp ? -0.025 : 0.045,
            child: const _SmartCard(),
          ),
        ),
        Positioned(left: 40, top: 30, child: _phoneBody(context, accent, phoneW, phoneH)),
        // NFC waves: above an iPhone, to the right of an Android phone (towards the card on its back)
        Positioned(
          left: _ios ? 40 : 230,
          top: _ios ? -40 : 200,
          width: _ios ? phoneW : 90,
          height: _ios ? 80 : 110,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: talking ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: AnimatedBuilder(
                animation: _waves,
                builder: (context, _) => CustomPaint(painter: _WavesPainter(_waves.value, accent, upward: _ios)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _phoneBody(BuildContext context, Color accent, double w, double h) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: w,
      height: h,
      padding: EdgeInsets.all(_ios ? 9 : 7),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _ios
              ? const [Color(0xFF3B4150), Color(0xFF1B1E26), Color(0xFF2E333F)]
              : const [Color(0xFF2B3A33), Color(0xFF141A17), Color(0xFF26332D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(_ios ? 42 : 30),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 30, offset: const Offset(0, 16))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_ios ? 34 : 24),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _ios
                  ? const [Color(0xFF0B1328), Color(0xFF111C3A), Color(0xFF0A0F1E)]
                  : const [Color(0xFF0B1A16), Color(0xFF10261F), Color(0xFF0A0F1E)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Stack(children: [
            Positioned(left: 18, right: 18, top: 12, child: _ios ? _iosStatusBar() : _androidStatusBar()),
            Positioned.fill(
              top: 46,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [
                  Text('NFC CARD TESTER',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 10, letterSpacing: 2)),
                  const SizedBox(height: 26),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: Container(
                      key: ValueKey(widget.phase),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.14),
                        border: Border.all(color: accent.withValues(alpha: 0.5), width: 2),
                      ),
                      child: Icon(phaseIcon(widget.phase), size: 54, color: accent),
                    ),
                  ),
                  const SizedBox(height: 18),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: FittedBox(
                      key: ValueKey(widget.title),
                      fit: BoxFit.scaleDown,
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.detail,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.72), fontSize: 12, height: 1.35),
                  ),
                ]),
              ),
            ),
            // while a session runs: the iOS "Ready to Scan" sheet, or an Android-style message
            AnimatedPositioned(
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              left: _ios ? 6 : 14,
              right: _ios ? 6 : 14,
              bottom: widget.busy ? (_ios ? 6 : 18) : -150,
              child: _ios ? _ScanSheet(accent: accent) : _AndroidToast(accent: accent),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _iosStatusBar() => Row(children: [
        const Text('9:41', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
        const Spacer(),
        Container(width: 70, height: 20, decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(12))),
        const Spacer(),
        const Icon(Icons.signal_cellular_alt_rounded, size: 12, color: Colors.white),
        const SizedBox(width: 3),
        const Icon(Icons.battery_full_rounded, size: 13, color: Colors.white),
      ]);

  Widget _androidStatusBar() => SizedBox(
        height: 20,
        child: Stack(children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('12:30', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
          Align(
            alignment: Alignment.center,
            child: Container(width: 12, height: 12, decoration: const BoxDecoration(color: Colors.black, shape: BoxShape.circle)),
          ),
          const Align(
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.nfc_rounded, size: 12, color: Colors.white),
              SizedBox(width: 3),
              Icon(Icons.wifi_rounded, size: 12, color: Colors.white),
              SizedBox(width: 3),
              Icon(Icons.battery_6_bar_rounded, size: 13, color: Colors.white),
            ]),
          ),
        ]),
      );
}

class _ScanSheet extends StatelessWidget {
  const _ScanSheet({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      decoration: BoxDecoration(color: const Color(0xFFF2F2F7), borderRadius: BorderRadius.circular(26)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Ready to Scan', style: TextStyle(color: Color(0xFF8E8E93), fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Icon(Icons.phonelink_ring_rounded, size: 34, color: accent),
        const SizedBox(height: 6),
        const Text('Hold the card near the top of the iPhone', textAlign: TextAlign.center, style: TextStyle(color: Colors.black87, fontSize: 11)),
        const SizedBox(height: 8),
        const LinearProgressIndicator(minHeight: 3),
      ]),
    );
  }
}

class _AndroidToast extends StatelessWidget {
  const _AndroidToast({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: const Color(0xFF2B2F36), borderRadius: BorderRadius.circular(14)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(Icons.contactless_rounded, size: 18, color: accent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Hold the card to the back of the phone',
                style: TextStyle(color: Colors.white, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: 8),
        const LinearProgressIndicator(minHeight: 3),
      ]),
    );
  }
}

class _SmartCard extends StatelessWidget {
  const _SmartCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      height: 101,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFBBF24), Color(0xFFF59E0B), Color(0xFFD97706)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30,
            height: 23,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFFFEF3C7), Color(0xFFFDE68A)]),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: const Color(0xFFB45309), width: 0.8),
            ),
          ),
          const Spacer(),
          const Icon(Icons.contactless_rounded, color: Colors.white, size: 22),
        ]),
        const Spacer(),
        const Text('EMG 0000000',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1.6)),
        Text('electrical_electrometer',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 9)),
      ]),
    );
  }
}

class _WavesPainter extends CustomPainter {
  _WavesPainter(this.t, this.color, {required this.upward});

  final double t;
  final Color color;
  final bool upward;

  @override
  void paint(Canvas canvas, Size size) {
    // upward: arcs above the phone top; otherwise arcs to the right, from the phone's side towards the card
    final center = upward ? Offset(size.width / 2, size.height + 6) : Offset(-6, size.height / 2);
    final start = upward ? -pi * 0.78 : -pi * 0.28;
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final radius = upward ? 18 + p * 64 : 14 + p * 70;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: (1 - p) * 0.85);
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, pi * 0.56, false, paint);
    }
  }

  @override
  bool shouldRepaint(_WavesPainter old) => old.t != t || old.color != color || old.upward != upward;
}
