import 'package:flutter/cupertino.dart'
    show
        CupertinoPageTransitionsBuilder,
        CupertinoTextThemeData,
        CupertinoThemeData;
import 'package:flutter/material.dart';
import 'solar.dart';

/// Тема «Афиша» — чистый чёрный фон, белый текст, минимум серого, лаймовый
/// акцент на нижнем меню. Шрифт — Inter (Alex 06.09.2026, вместо узкого Oswald:
/// тот сильно жал буквы в плеере). Inter вшит в приложение, с кириллицей,
/// начертания 400/500/600/700; тот же шрифт стоит в ФармМастере.
///
/// Оформление «как у Apple» (Alex TG 20345, 21.09.2026): тёмная тема iOS —
/// сгруппированные списки на серых плашках (`groupBg`), тонкие разделители
/// (`sep`), переходы и прокрутка как на iPhone, значки Cupertino. Фирменный
/// лайм остаётся цветом выбранного (как «tint» в iOS).
class Afisha {
  static const Color bg = Color(0xFF000000);
  static const Color surface = Color(0xFF0F0F0F);
  static const Color surfaceHi = Color(0xFF1C1C1E);
  static const Color lime = Color(0xFFB2FF00);
  static const Color ink = Color(0xFFF4F4F5);
  static const Color inkDim = Color(0xFF9B9B9B);
  static const Color line = Color(0xFF222222);

  // Системные цвета iOS (тёмная тема): плашки списков, разделитель, значки.
  static const Color groupBg = Color(0xFF1C1C1E);
  static const Color groupHi = Color(0xFF2C2C2E);
  static const Color sep = Color(0xFF38383A);
  static const Color chevron = Color(0xFF636366);
  static const Color red = Color(0xFFFF453A);
  static const Color green = Color(0xFF30D158);
  static const Color blue = Color(0xFF0A84FF);
  static const Color gray = Color(0xFF8E8E93);

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
      // iOS: нажатие — лёгкое серое затемнение, без «волны» Material.
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: const Color(0x14FFFFFF),
      cupertinoOverrideTheme: const CupertinoThemeData(
        brightness: Brightness.dark,
        primaryColor: lime,
        scaffoldBackgroundColor: bg,
        barBackgroundColor: Color(0xCC000000),
        textTheme: CupertinoTextThemeData(
          navLargeTitleTextStyle: TextStyle(
            fontFamily: fontFamily,
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
            color: ink,
          ),
          navTitleTextStyle: TextStyle(
            fontFamily: fontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
            color: ink,
          ),
          textStyle: TextStyle(fontFamily: fontFamily, fontSize: 17, color: ink),
        ),
      ),
      textTheme: base.textTheme.apply(fontFamily: fontFamily).copyWith(
            headlineSmall: const TextStyle(
                fontWeight: FontWeight.w600, letterSpacing: 0.2, color: ink),
            titleLarge: const TextStyle(
                fontWeight: FontWeight.w600, letterSpacing: 0.2, color: ink),
            titleMedium: const TextStyle(fontWeight: FontWeight.w500, color: ink),
          ),
      // Переходы как на iPhone на обеих платформах: экран выезжает справа,
      // предыдущий слегка сдвигается; возврат — смахиванием от левого края.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        toolbarHeight: 48,
        iconTheme: IconThemeData(color: lime),
        actionsIconTheme: IconThemeData(color: lime),
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: ink,
        ),
      ),
      actionIconTheme: ActionIconThemeData(
        backButtonIconBuilder: (_) => const Icon(SolarOutline.altArrowLeft, size: 30),
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
          minimumSize: const Size(64, 50),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontWeight: FontWeight.w600,
            fontSize: 17,
            letterSpacing: -0.4,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: lime,
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontWeight: FontWeight.w500,
            fontSize: 16,
            letterSpacing: -0.3,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: groupHi,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: const TextStyle(
          fontFamily: fontFamily,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: ink,
        ),
        contentTextStyle: const TextStyle(
          fontFamily: fontFamily,
          fontSize: 14,
          height: 1.3,
          color: inkDim,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: groupBg,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: groupBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: groupHi,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(
          fontFamily: fontFamily,
          fontSize: 16,
          letterSpacing: -0.3,
          color: ink,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: lime),
      dividerTheme: const DividerThemeData(color: sep, thickness: 0.5, space: 0.5),
      dividerColor: line,
    );
  }
}
