import 'package:flutter/material.dart';

import '../state/app_state.dart';

const seed = Color(0xFF5B7CFA);
const okColor = Color(0xFF22C55E);
const warnColor = Color(0xFFF59E0B);
const failColor = Color(0xFFEF4444);
const blockedColor = Color(0xFF8B5CF6);
const infoColor = Color(0xFF64748B);
const nfcColor = Color(0xFF22D3EE);

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF0A0F1E) : const Color(0xFFF3F5FA),
    fontFamily: 'Segoe UI',
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
  );
}

bool isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

Color panelColor(BuildContext context) => isDark(context) ? const Color(0xFF121A30) : Colors.white;

Color borderColor(BuildContext context) =>
    isDark(context) ? Colors.white.withValues(alpha: 0.07) : Colors.black.withValues(alpha: 0.07);

Color subtleText(BuildContext context) => isDark(context) ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

TextStyle mono({double size = 13, Color? color, FontWeight? weight}) => TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['Cascadia Mono', 'Courier New'],
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: 1.35,
    );

class StatusStyle {
  const StatusStyle(this.color, this.icon, this.label);

  final Color color;
  final IconData icon;
  final String label;
}

StatusStyle statusStyle(String result) {
  switch (result) {
    case 'OK':
    case 'PASS':
      return StatusStyle(okColor, Icons.check_circle_rounded, result);
    case 'WARN':
      return const StatusStyle(warnColor, Icons.warning_amber_rounded, 'WARN');
    case 'NOTE':
      return const StatusStyle(warnColor, Icons.sticky_note_2_outlined, 'NOTE');
    case 'FAIL':
      return const StatusStyle(failColor, Icons.cancel_rounded, 'FAIL');
    case 'BLOCKED':
      return const StatusStyle(blockedColor, Icons.block_rounded, 'BLOCKED');
    default:
      return const StatusStyle(infoColor, Icons.info_outline_rounded, 'INFO');
  }
}

Color phaseColor(PhonePhase phase) {
  switch (phase) {
    case PhonePhase.idle:
      return const Color(0xFF60A5FA);
    case PhonePhase.tapping:
    case PhonePhase.connected:
      return nfcColor;
    case PhonePhase.success:
      return okColor;
    case PhonePhase.warning:
      return warnColor;
    case PhonePhase.failure:
      return failColor;
  }
}

IconData phaseIcon(PhonePhase phase) {
  switch (phase) {
    case PhonePhase.idle:
      return Icons.contactless_outlined;
    case PhonePhase.tapping:
      return Icons.nfc_rounded;
    case PhonePhase.connected:
      return Icons.sensors_rounded;
    case PhonePhase.success:
      return Icons.verified_rounded;
    case PhonePhase.warning:
      return Icons.verified_outlined;
    case PhonePhase.failure:
      return Icons.cancel_rounded;
  }
}
