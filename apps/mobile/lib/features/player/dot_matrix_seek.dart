import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'player_controller.dart';

/// «1:12» — минуты без ведущего нуля, секунды двумя цифрами. Часы не выделяем:
/// длинные записи показываются как «100:05», как и раньше в плеере.
String formatMmss(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Что показывать справа от точек (Alex TG 19.09.2026 выбирал, что делать с
/// общей длиной песни, которой на картинке варианта 19 не было).
enum DotMatrixTotal {
  /// Ничего — только крупные цифры «сколько прошло», как на картинке.
  none,

  /// Общая длина маленькой цифрой («4:33»).
  small,

  /// Сколько осталось («−3:21»).
  remaining,
}

/// Полоса перемотки «точечная матрица + цифры» (вариант 19 из подборки
/// 19.09.2026, «давай 19 попробуем»). Слева крупные цифры — сколько песни
/// прошло, дальше 5 рядов по 40 квадратиков: пройденные колонки закрашены
/// цветом [tint] (у обложки свой цвет), остальные тусклые. Тап или ведение
/// пальцем по точкам перематывает песню.
///
/// Ничего не берёт с сервера — хватает позиции и длины трека. Раньше здесь
/// была волна из 64 столбиков: форму громкости приходилось спрашивать у
/// сервера при каждой смене песни (без связи — 8 секунд пустого ожидания и
/// «случайная» заглушка); принцип «сервер считает — телефон сам» (см.
/// docs/SOUNDFLOW_OFFLINE_FIRST_PLAN.md) решили здесь просто убрать
/// зависимость.
class DotMatrixSeek extends StatelessWidget {
  const DotMatrixSeek({
    super.key,
    required this.controller,
    required this.tint,
    this.total = DotMatrixTotal.small,
  });

  final PlayerController controller;
  final Color tint;
  final DotMatrixTotal total;

  static const cols = 40;
  static const rows = 5;
  static const _height = 46.0;

  static const _digitStyle = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w600,
    height: 1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Ширина под цифры — по самой длинной записи ЭТОГО трека («4:33» → «0:00»),
  /// чтобы точки не «прыгали», пока секунды и минуты меняются. Все цифры
  /// табличные (одной ширины), поэтому нули как образец подходят.
  double _digitsWidth(BuildContext context, Duration duration) {
    final template = formatMmss(duration).replaceAll(RegExp(r'\d'), '0');
    final painter = TextPainter(
      text: TextSpan(text: template, style: DefaultTextStyle.of(context).style.merge(_digitStyle)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width + 2;
  }

  void _seekAt(double dx, double width, int totalMs) {
    if (totalMs <= 0 || width <= 0) return;
    controller.seek(Duration(milliseconds: (totalMs * (dx / width).clamp(0.0, 1.0)).round()));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: controller.duration,
      builder: (_, dur, _) => ValueListenableBuilder<Duration>(
        valueListenable: controller.position,
        builder: (_, pos, _) {
          final totalMs = dur.inMilliseconds;
          final frac = totalMs <= 0 ? 0.0 : (pos.inMilliseconds / totalMs).clamp(0.0, 1.0);
          final side = switch (total) {
            DotMatrixTotal.none => null,
            DotMatrixTotal.small => formatMmss(dur),
            DotMatrixTotal.remaining => '−${formatMmss(dur - pos < Duration.zero ? Duration.zero : dur - pos)}',
          };
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SizedBox(
              height: _height,
              child: Row(children: [
                SizedBox(
                  width: _digitsWidth(context, dur),
                  child: Text(
                    formatMmss(pos),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: _digitStyle.copyWith(color: tint),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => GestureDetector(
                      key: const ValueKey('dot_matrix_seek_area'),
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => _seekAt(d.localPosition.dx, c.maxWidth, totalMs),
                      onHorizontalDragUpdate: (d) => _seekAt(d.localPosition.dx, c.maxWidth, totalMs),
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _MatrixPainter(
                          progress: frac,
                          played: tint,
                          rest: Colors.white.withValues(alpha: 0.16),
                        ),
                      ),
                    ),
                  ),
                ),
                if (side != null) ...[
                  const SizedBox(width: 10),
                  Text(side, style: const TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _MatrixPainter extends CustomPainter {
  const _MatrixPainter({required this.progress, required this.played, required this.rest});

  final double progress;
  final Color played;
  final Color rest;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    const cols = DotMatrixSeek.cols;
    const rows = DotMatrixSeek.rows;
    final cw = size.width / cols;
    final rh = size.height / rows;
    final base = math.min(cw, rh) * 0.64;
    // Колонка, в которой сейчас «бегунок»: закрашена всегда (на 0:00 горит
    // первая) и чуть крупнее остальных — видно точное место.
    final head = (progress * cols).floor().clamp(0, cols - 1);
    final onPaint = Paint()..color = played;
    final offPaint = Paint()..color = rest;
    for (var i = 0; i < cols; i++) {
      final dot = i == head ? base * 1.2 : base;
      for (var j = 0; j < rows; j++) {
        final center = Offset(i * cw + cw / 2, j * rh + rh / 2);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: center, width: dot, height: dot), Radius.circular(dot * 0.25)),
          i <= head ? onPaint : offPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MatrixPainter old) =>
      old.progress != progress || old.played != played || old.rest != rest;
}
