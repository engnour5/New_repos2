import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/error_map.dart';
import 'theme.dart';

/// Keeps a hex box in capitals while it is typed.
class UpperCaseText extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue value) =>
      value.copyWith(text: value.text.toUpperCase());
}

/// A rounded panel with a soft border.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.gradient});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? panelColor(context) : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark(context) ? 0.25 : 0.05),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// A coloured pill: PASS, FAIL, WARN ...
class StatusChip extends StatelessWidget {
  const StatusChip(this.result, {super.key, this.dense = false});

  final String result;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final s = statusStyle(result);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(
        color: s.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: s.color.withValues(alpha: 0.45)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.icon, size: dense ? 13 : 15, color: s.color),
        const SizedBox(width: 5),
        Text(s.label, style: TextStyle(color: s.color, fontWeight: FontWeight.w700, fontSize: dense ? 11 : 12, letterSpacing: 0.4)),
      ]),
    );
  }
}

/// A small coloured count: "39 PASS".
class CountChip extends StatelessWidget {
  const CountChip({super.key, required this.count, required this.label, required this.color, required this.icon});

  final int count;
  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: count > 0 ? 0.16 : 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: count.toDouble()),
          duration: const Duration(milliseconds: 400),
          builder: (context, v, _) => Text('${v.round()}', style: TextStyle(fontWeight: FontWeight.w800, color: color, fontSize: 15)),
        ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
      ]),
    );
  }
}

/// Fades and slides a child in the first time it is built.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({super.key, required this.child, this.offset = 14});

  final Widget child;
  final double offset;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * offset), child: child),
      ),
      child: child,
    );
  }
}

/// A progress ring with a gradient stroke that animates to [value].
class ProgressRing extends StatelessWidget {
  const ProgressRing({super.key, required this.value, required this.colors, this.size = 120, this.stroke = 11, this.child});

  final double value;
  final List<Color> colors;
  final double size;
  final double stroke;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(v, colors, stroke, borderColor(context)),
          child: Center(child: child),
        ),
      ),
      child: child,
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.colors, this.stroke, this.track);

  final double value;
  final List<Color> colors;
  final double stroke;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2);
    canvas.drawArc(arcRect, 0, 2 * pi, false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = track);
    if (value <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: -pi / 2,
        endAngle: 3 * pi / 2,
        colors: colors,
        transform: const GradientRotation(-pi / 2),
      ).createShader(rect);
    canvas.drawArc(arcRect, -pi / 2, 2 * pi * value, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.colors != colors || old.track != track;
}

/// Shows one page at a time with a cross-fade, and keeps the state of the others.
class FadeIndexedStack extends StatelessWidget {
  const FadeIndexedStack({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      for (var i = 0; i < children.length; i++)
        IgnorePointer(
          ignoring: i != index,
          child: ExcludeFocus(
            excluding: i != index,
            child: AnimatedOpacity(
              opacity: i == index ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: TickerMode(enabled: i == index, child: children[i]),
            ),
          ),
        ),
    ]);
  }
}

/// A friendly placeholder for empty lists.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(icon, size: 40, color: color),
          ),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: subtleText(context))),
          ),
        ]),
      ),
    );
  }
}

/// A heading inside a panel.
class PanelHeader extends StatelessWidget {
  const PanelHeader({super.key, required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 8),
      Expanded(
        child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      ),
      ?trailing,
    ]);
  }
}

/// The colour of an answer type of the error map.
Color answerColor(AnswerKind kind) => switch (kind) {
      AnswerKind.success => okColor,
      AnswerKind.appletError => seed,
      AnswerKind.originalApplet => warnColor,
      AnswerKind.wrongData || AnswerKind.unexpected => failColor,
    };

/// A small tag with the type of an answer ("READ 2", "OLD F8" ...); the tooltip has the whole explanation.
class AnswerChip extends StatelessWidget {
  const AnswerChip(this.answer, {super.key});

  final AnswerType answer;

  @override
  Widget build(BuildContext context) {
    final color = answerColor(answer.kind);
    return Tooltip(
      message: answer.text,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(answer.tag,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.3)),
      ),
    );
  }
}

/// Opens a web link in the default browser.
Future<void> openLink(String url) async {
  await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
}

/// The Windows "open file" dialog, asked for through PowerShell. A Flutter plugin would do this too, but plugins
/// need Developer Mode turned on, and this needs nothing. Returns null when the dialog is cancelled.
Future<String?> pickFile({required String title, required String filter, String? startIn}) async {
  String text(String s) => "'${s.replaceAll("'", "''")}'";
  final command = [
    'Add-Type -AssemblyName System.Windows.Forms;',
    r'$d = New-Object System.Windows.Forms.OpenFileDialog;',
    '\$d.Title = ${text(title)};',
    '\$d.Filter = ${text(filter)};',
    if (startIn != null && startIn.isNotEmpty) '\$d.InitialDirectory = ${text(startIn)};',
    r'if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Out.Write($d.FileName) }',
  ].join(' ');
  try {
    final r = await Process.run('powershell', ['-STA', '-NoProfile', '-Command', command]);
    final path = '${r.stdout}'.trim();
    return path.isEmpty ? null : path;
  } catch (_) {
    return null; // no dialog available: the box can still be typed into
  }
}
