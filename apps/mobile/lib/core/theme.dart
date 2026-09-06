import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Тема «Афиша» — чистый чёрный фон, белый текст, минимум серого, лаймовый
/// акцент на нижнем меню. Шрифт — Inter (Alex 06.09.2026, вместо узкого Oswald:
/// тот сильно жал буквы в плеере). Inter вшит в приложение, с кириллицей,
/// начертания 400/500/600/700; тот же шрифт стоит в ФармМастере.
class Afisha {
  static const Color bg = Color(0xFF000000);
  static const Color surface = Color(0xFF0F0F0F);
  static const Color surfaceHi = Color(0xFF1A1A1A);
  static const Color lime = Color(0xFFB2FF00);
  static const Color ink = Color(0xFFF4F4F5);
  static const Color inkDim = Color(0xFF9B9B9B);
  static const Color line = Color(0xFF222222);

  static const String fontFamily = 'Inter';

  static ThemeData theme() {
    final base = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      fontFamily: fontFamily,
      colorScheme: const ColorScheme.dark(
        surface: bg,
        primary: lime,
        onPrimary: Color(0xFF000000),
        secondary: lime,
        onSurface: ink,
      ),
      useMaterial3: true,
    );

    return base.copyWith(
      splashColor: lime.withValues(alpha: 0.12),
      highlightColor: lime.withValues(alpha: 0.06),
      textTheme: base.textTheme.apply(fontFamily: fontFamily).copyWith(
            headlineSmall: const TextStyle(
                fontWeight: FontWeight.w600, letterSpacing: 0.2, color: ink),
            titleLarge: const TextStyle(
                fontWeight: FontWeight.w600, letterSpacing: 0.2, color: ink),
            titleMedium: const TextStyle(fontWeight: FontWeight.w500, color: ink),
          ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        elevation: 0,
        indicatorColor: lime.withValues(alpha: 0.13),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontFamily: fontFamily,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
            color: s.contains(WidgetState.selected) ? lime : inkDim,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? lime : inkDim,
          ),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: ink,
        ),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: lime,
        inactiveTrackColor: line,
        thumbColor: lime,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: lime,
          foregroundColor: const Color(0xFF000000),
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontWeight: FontWeight.w600,
            fontSize: 15,
            letterSpacing: 0.3,
          ),
        ),
      ),
      dividerColor: line,
    );
  }
}
