import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Trader Copilot design system.
///
/// Dark-first fintech aesthetic: deep navy surfaces, emerald gains, soft red
/// losses, amber warnings, and tabular figures so numbers never jitter.
abstract final class TC {
  // Palette ---------------------------------------------------------------
  static const bg = Color(0xFF0B1220);
  static const surface = Color(0xFF121A2B);
  static const surfaceHi = Color(0xFF1A2438);
  static const outline = Color(0xFF26324A);
  static const onBg = Color(0xFFE7EEF8);
  static const onBgDim = Color(0xFF8FA0B8);
  static const gain = Color(0xFF34D399);
  static const loss = Color(0xFFF97066);
  static const warn = Color(0xFFFBBF24);
  static const info = Color(0xFF60A5FA);
  static const heroGradient = [Color(0xFF10382B), Color(0xFF122C45)];

  /// Rotating accents for symbol avatars / allocation slices.
  static const accents = [
    gain,
    info,
    warn,
    Color(0xFFA78BFA),
    Color(0xFF2DD4BF),
    Color(0xFFFB7185),
  ];

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: gain,
      onPrimary: Color(0xFF052A1D),
      secondary: warn,
      onSecondary: Color(0xFF271B02),
      error: loss,
      onError: Color(0xFF2B0707),
      surface: surface,
      onSurface: onBg,
      surfaceContainerHighest: surfaceHi,
      outline: outline,
      outlineVariant: outline,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
    );
    return base.copyWith(
      textTheme: _textTheme(base.textTheme),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: outline),
        ),
      ),
      dividerTheme: const DividerThemeData(color: outline, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHi,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: gain, width: 1.4),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: gain,
          foregroundColor: const Color(0xFF052A1D),
          minimumSize: const Size(0, 48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle:
              const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: onBg,
          minimumSize: const Size(0, 48),
          side: const BorderSide(color: outline),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          side: const WidgetStatePropertyAll(BorderSide(color: outline)),
        ),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: gain,
        inactiveTrackColor: surfaceHi,
        thumbColor: gain,
        overlayColor: Color(0x2234D399),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: const Color(0x2234D399),
        height: 66,
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: onBgDim),
        ),
        iconTheme: const WidgetStatePropertyAll(
          IconThemeData(color: onBgDim),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: bg,
        indicatorColor: const Color(0x2234D399),
        selectedLabelTextStyle: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w700, color: TC.onBg),
        unselectedLabelTextStyle: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, color: TC.onBgDim),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceHi,
        contentTextStyle: const TextStyle(color: onBg),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: outline),
        ),
      ),
      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
          color: surfaceHi,
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        textStyle: TextStyle(color: onBg, fontSize: 12),
      ),

    );
  }

  static TextTheme _textTheme(TextTheme t) {
    const tabular = [FontFeature.tabularFigures()];
    TextStyle f(
      TextStyle s, {
      double? size,
      FontWeight? w,
      double? ls,
      Color? c,
    }) =>
        s.copyWith(
          fontSize: size,
          fontWeight: w,
          letterSpacing: ls,
          color: c,
          fontFeatures: tabular,
        );
    return t.apply(bodyColor: onBg, displayColor: onBg).copyWith(
          headlineLarge:
              f(t.headlineLarge!, size: 32, w: FontWeight.w800, ls: -0.8),
          headlineMedium:
              f(t.headlineMedium!, size: 26, w: FontWeight.w800, ls: -0.6),
          titleLarge: f(t.titleLarge!, size: 19, w: FontWeight.w700, ls: -0.3),
          titleMedium: f(t.titleMedium!, size: 16, w: FontWeight.w700),
          titleSmall: f(t.titleSmall!, size: 13.5, w: FontWeight.w600),
          bodyLarge: f(t.bodyLarge!, size: 15),
          bodyMedium: f(t.bodyMedium!, size: 14),
          bodySmall: f(t.bodySmall!, size: 12.5, c: onBgDim),
          labelLarge: f(t.labelLarge!, w: FontWeight.w700),
        );
  }
}
