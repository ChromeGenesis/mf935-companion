import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Rhema-inspired design tokens (SSOT): glass surfaces, amber accent +
/// indigo ambient glow, Outfit type. Light and dark palettes; widgets
/// read colors via `context.zc`, never hardcode.
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
  final Color glass;
  final Color glassHighlight;

  /// Inner-tile glass: low-alpha fill + border for chips/tiles
  /// (TradeMum parity — ambient colors read through).
  final Color chip;
  final Color chipBorder;
  final Color onAccent;
  final Brightness brightness;

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
    required this.glass,
    required this.glassHighlight,
    required this.chip,
    required this.chipBorder,
    required this.onAccent,
    required this.brightness,
  });

  /// Dark: near-black scaffold, frosted white borders.
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
    glass: Color(0x14FFFFFF),
    glassHighlight: Color(0x2EFFFFFF),
    // TradeMum-parity chip glass: low-alpha foreground fills (alpha 10–20)
    // instead of opaque black70 — ambient orbs read through inner tiles.
    chip: Color(0x14FFFFFF),
    chipBorder: Color(0x20FFFFFF),
    onAccent: Color(0xFF0A0A0A),
    brightness: Brightness.dark,
  );

  /// Light: warm paper scaffold, slate text, same amber accent family.
  static const light = ZteColors(
    scaffold: Color(0xFFF6F4EF),
    surface: Color(0xFFFFFFFF),
    surfaceLifted: Color(0xFFF0EDE6),
    border: Color(0x2E1E293B),
    borderSubtle: Color(0x171E293B),
    accent: Color(0xFFD97706),
    accentGlow: Color(0x40D97706),
    accentText: Color(0xFFB45309),
    orbSecondary: Color(0xFF6366F1),
    live: Color(0xFF059669),
    danger: Color(0xFFDC2626),
    textPrimary: Color(0xFF1E293B),
    textSecondary: Color(0xFF475569),
    textMuted: Color(0xFF64748B),
    inputBg: Color(0x14000000),
    glass: Color(0x33FFFFFF),
    glassHighlight: Color(0x59FFFFFF),
    chip: Color(0x0A000000),
    chipBorder: Color(0x171E293B),
    onAccent: Color(0xFFFFFFFF),
    brightness: Brightness.light,
  );

  @override
  ThemeExtension<ZteColors> copyWith() => this;

  @override
  ThemeExtension<ZteColors> lerp(ThemeExtension<ZteColors>? other, double t) =>
      other is ZteColors && t > 0.5 ? other : this;
}

extension ZteThemeX on BuildContext {
  ZteColors get zc =>
      Theme.of(this).extension<ZteColors>() ?? ZteColors.dark;
}

/// Centralized system-chrome management (TradeMum `TMSystemUI` parity).
/// Transparent status bar with brightness-aware icons: light icons on
/// the dark theme, dark icons on the light theme — so the clock,
/// signal and battery glyphs stay legible over the ambient background
/// instead of washing out. Explicit (rather than inherited) so stubborn
/// devices never fall back to an unreadable default.
class ZSystemUI {
  static SystemUiOverlayStyle overlay(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    );
  }
}

/// Typography shared by both themes: Outfit everywhere.
TextTheme _zteTextTheme(Brightness b) => GoogleFonts.outfitTextTheme(
      (b == Brightness.dark ? ThemeData.dark() : ThemeData.light()).textTheme,
    );

/// Build the app theme for either brightness.
ThemeData buildZteTheme({Brightness brightness = Brightness.dark}) {
  final c = brightness == Brightness.dark ? ZteColors.dark : ZteColors.light;
  final text = _zteTextTheme(brightness);
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: c.scaffold,
    canvasColor: c.surface,
    cardColor: c.surface,
    splashFactory: InkSparkle.splashFactory,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: c.accent,
      secondary: c.live,
      surface: c.surface,
      error: c.danger,
      onPrimary: c.onAccent,
      onSecondary: c.onAccent,
      onSurface: c.textPrimary,
      onError: Colors.white,
      outlineVariant: c.borderSubtle,
    ),
    textTheme: text,
    useMaterial3: true,
    dividerTheme: DividerThemeData(color: c.borderSubtle, thickness: 1),
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
        foregroundColor: c.onAccent,
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
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.accentText),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      iconColor: c.textMuted,
      collapsedIconColor: c.textMuted,
      textColor: c.textSecondary,
      collapsedTextColor: c.textSecondary,
    ),
    cardTheme: const CardThemeData(clipBehavior: Clip.antiAlias),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? null : c.surfaceLifted,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
    ),
    extensions: [c],
  );
}
