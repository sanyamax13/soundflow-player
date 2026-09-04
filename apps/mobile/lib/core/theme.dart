import 'package:flutter/material.dart';

/// Тема «Афиша» — переносится один-в-один со старого веба:
/// почти-чёрный фон, лаймовый акцент, узкий гротеск.
/// (См. docs старого проекта: near-black + лайм #C6F000 + Bahnschrift.)
class Afisha {
  static const Color bg = Color(0xFF0B0B0B);
  static const Color surface = Color(0xFF141414);
  static const Color surfaceHi = Color(0xFF1E1E1E);
  static const Color lime = Color(0xFFC6F000);
  static const Color ink = Color(0xFFF5F5F5);
  static const Color inkDim = Color(0xFF9A9A9A);
  static const Color line = Color(0xFF2A2A2A);

  /// Bahnschrift есть только на Windows. На Android настоящий шрифт «Афиши»
  /// будет вшит в приложение отдельным шагом; пока — системный.
  static ThemeData theme() {
    final base = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        surface: bg,
        primary: lime,
        onPrimary: Color(0xFF0B0B0B),
        secondary: lime,
        onSurface: ink,
      ),
      useMaterial3: true,
    );
    return base.copyWith(
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: lime.withValues(alpha: 0.16),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 11, color: inkDim),
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
      ),
    );
  }
}
