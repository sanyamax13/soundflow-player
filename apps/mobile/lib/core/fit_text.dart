import 'package:flutter/material.dart';

/// Текст, который сам уменьшает шрифт, чтобы влезть целиком (27.09.2026, Alex: «название не всё
/// влезает, автомасштабирование давай сделаем»). Пробует от размера в [style] вниз до [minFontSize]
/// в [maxLines] строк; не влезло и на минимуме — ещё раз в [fallbackMaxLines] строк; дальше «…».
class FitText extends StatelessWidget {
  const FitText(
    this.text, {
    super.key,
    required this.style,
    this.maxLines = 1,
    this.minFontSize = 12,
    this.fallbackMaxLines,
  });

  final String text;
  final TextStyle style;
  final int maxLines;
  final double minFontSize;
  final int? fallbackMaxLines;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final scaler = MediaQuery.textScalerOf(context);
      final dir = Directionality.of(context);
      // Мерить тем же шрифтом, каким нарисует Text: стиль экрана (Inter) + наш. Без этого мерили
      // шрифтом по умолчанию — он у́же Inter, и «влезало» то, что на экране обрезалось «…»
      // (Alex, скрин 27.09.2026: «где автомасштабирование?»).
      final base = DefaultTextStyle.of(context).style.merge(style);
      bool fits(double size, int lines) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: base.copyWith(fontSize: size)),
          maxLines: lines,
          textDirection: dir,
          textScaler: scaler,
        )..layout(maxWidth: c.maxWidth);
        return !tp.didExceedMaxLines;
      }

      final top = base.fontSize ?? 14;
      var size = top;
      var lines = maxLines;
      while (size > minFontSize && !fits(size, lines)) {
        size -= 1;
      }
      if (size <= minFontSize) {
        size = minFontSize;
        if (fallbackMaxLines != null && !fits(size, lines)) lines = fallbackMaxLines!;
      }
      final t = style.copyWith(fontSize: size);
      if (lines > 1) return Text(text, maxLines: lines, overflow: TextOverflow.ellipsis, style: t);
      // Одна строка — страховка на случай, если телефон рисует шире, чем намерили (Alex, скрин
      // 28.09.2026: на Samsung «Tyga feat. G-Eazy & Rich The …» так и обрезалось «…» при верном
      // замере в тестах): строка целиком, а не влезает — ужимается ещё, до ширины места.
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Text(text, maxLines: 1, softWrap: false, style: t),
      );
    });
  }
}
