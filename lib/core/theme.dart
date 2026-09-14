import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Rhema-inspired dark design tokens: near-black scaffold, glass surfaces,
/// amber accent + indigo ambient glow, Outfit type.
class ZteColors extends ThemeExtension<ZteColors> {
  final Color scaffold;
  final Color surface;
  final Color surfaceLifted;
  final Color border;
  final Color borderSubtle;
  final Color accent;
  final Color accentGlow;
  final Color accentText;
  final Color orbSecondary;
  final Color live;
  final Color danger;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color inputBg;

  const ZteColors({
    required this.scaffold,
    required this.surface,
    required this.surfaceLifted,
    required this.border,
    required this.borderSubtle,
    required this.accent,
    required this.accentGlow,
    required this.accentText,
    required this.orbSecondary,
    required this.live,
    required this.danger,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.inputBg,
  });

  static const dark = ZteColors(
    scaffold: Color(0xFF050505),
    surface: Color(0xFF0B0B0C),
    surfaceLifted: Color(0xFF141416),
    border: Color(0x2BFFFFFF),
    borderSubtle: Color(0x14FFFFFF),
    accent: Color(0xFFF59E0B),
    accentGlow: Color(0x50F59E0B),
    accentText: Color(0xFFFBBF24),
    orbSecondary: Color(0xFF312E81),
    live: Color(0xFF10B981),
    danger: Color(0xFFEF4444),
    textPrimary: Color(0xFFF8FAFC),
    textSecondary: Color(0xFF94A3B8),
    textMuted: Color(0xFF64748B),
    inputBg: Color(0xCC000000),
  );

  @override
  ThemeExtension<ZteColors> copyWith() => this;

  @override
  ThemeExtension<ZteColors> lerp(ThemeExtension<ZteColors>? other, double t) =>
      this;
}

extension ZteThemeX on BuildContext {
  ZteColors get zc =>
      Theme.of(this).extension<ZteColors>() ?? ZteColors.dark;
}

ThemeData buildZteTheme() {
  const c = ZteColors.dark;
  final text = GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme);
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: c.scaffold,
    canvasColor: c.surface,
    cardColor: c.surface,
    splashFactory: InkSparkle.splashFactory,
    colorScheme: ColorScheme.dark(
      primary: c.accent,
      secondary: c.live,
      surface: c.surface,
      error: c.danger,
      onPrimary: c.scaffold,
      onSurface: c.textPrimary,
    ),
    textTheme: text,
    useMaterial3: true,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.inputBg,
      hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
      labelStyle: TextStyle(color: c.textSecondary, fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.borderSubtle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.accent, width: 1.4),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: Colors.black,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.textPrimary,
        side: BorderSide(color: c.border),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    cardTheme: const CardThemeData(clipBehavior: Clip.antiAlias),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
    ),
    extensions: const [c],
  );
}
