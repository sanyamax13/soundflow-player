import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
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

/// Полоса перемотки «пляшущий эквалайзер» (Опус-ревью «Поток» 23.09.2026:
/// вместо точечной матрицы варианта 19 — Alex выбрал вариант 11 из подборки
/// эскизов, `apps/mobile/test/equalizer_variants_shot.dart`: много тонких
/// столбиков-«спектроанализатор», каждый сам разбит на 3 цветные зоны по
/// высоте — лайм внизу («тихо»), синий в середине, красный на самом верху
/// («громко»), как на старом аппаратном эквалайзере/VU-метре. Слева крупные
/// цифры — сколько прошло. Тап или ведение пальцем по столбикам перематывает
/// песню.
///
/// Столбики «пляшут» непрерывно, пока трек играет (гладкое псевдослучайное
/// колебание высоты, своя скорость/фаза на столбик, фиксированный seed) —
/// настоящего звукового анализа в реальном времени нет и не будет (принцип
/// «сервер считает — телефон сам», см. docs/SOUNDFLOW_OFFLINE_FIRST_PLAN.md),
/// это имитация, как в `equalizer_animation_shot.dart`. На паузе — замирают.
/// Ничего не берёт с сервера: только позиция и длина трека, которые и так
/// есть у телефона.
class DotMatrixSeek extends StatefulWidget {
  const DotMatrixSeek({
    super.key,
    required this.controller,
    required this.tint,
    this.total = DotMatrixTotal.small,
  });

  final PlayerController controller;

  /// Цвет крупных цифр «сколько прошло» (обычно цвет обложки) — сами
  /// столбики эквалайзера в фирменных лайм/синий/красный, независимо от
  /// обложки (Alex TG 23.09.2026: «лайм — это наш дефолтный цвет»).
  final Color tint;
  final DotMatrixTotal total;

  static const _height = 46.0;

  static const _digitStyle = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  @override
  State<DotMatrixSeek> createState() => _DotMatrixSeekState();
}

class _EqBar {
  const _EqBar(this.envelope, this.speed, this.phase);
  final double envelope;
  final double speed;
  final double phase;
}

class _DotMatrixSeekState extends State<DotMatrixSeek> with SingleTickerProviderStateMixin {
  static const _cols = 64;

  late final AnimationController _ticker;
  final Stopwatch _clock = Stopwatch();
  late final List<_EqBar> _bars;

  @override
  void initState() {
    super.initState();
    // Просто «метроном» перерисовки — само время берём из Stopwatch (его
    // можно ставить на паузу вместе с треком, не теряя фазу пляски).
    _ticker = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();
    final rnd = math.Random(5);
    _bars = List<_EqBar>.generate(_cols, (_) {
      final env = 0.18 + rnd.nextDouble() * 0.82;
      final speed = 0.7 + rnd.nextDouble() * 1.6; // циклов в секунду
      final phase = rnd.nextDouble();
      return _EqBar(env, speed, phase);
    });
    widget.controller.playing.addListener(_syncPlaying);
    _syncPlaying();
  }

  void _syncPlaying() {
    if (widget.controller.playing.value) {
      if (!_clock.isRunning) _clock.start();
    } else {
      _clock.stop();
    }
  }

  @override
  void dispose() {
    widget.controller.playing.removeListener(_syncPlaying);
    _ticker.dispose();
    super.dispose();
  }

  /// Ширина под цифры — по самой длинной записи ЭТОГО трека («4:33» → «0:00»),
  /// чтобы столбики не «прыгали» по горизонтали, пока секунды и минуты
  /// меняются. Все цифры табличные (одной ширины), поэтому нули как образец
  /// подходят.
  double _digitsWidth(BuildContext context, Duration duration) {
    final template = formatMmss(duration).replaceAll(RegExp(r'\d'), '0');
    final painter = TextPainter(
      text: TextSpan(text: template, style: DefaultTextStyle.of(context).style.merge(DotMatrixSeek._digitStyle)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width + 2;
  }

  void _seekAt(double dx, double width, int totalMs) {
    if (totalMs <= 0 || width <= 0) return;
    widget.controller.seek(Duration(milliseconds: (totalMs * (dx / width).clamp(0.0, 1.0)).round()));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.controller.duration,
      builder: (_, dur, _) => ValueListenableBuilder<Duration>(
        valueListenable: widget.controller.position,
        builder: (_, pos, _) {
          final totalMs = dur.inMilliseconds;
          final frac = totalMs <= 0 ? 0.0 : (pos.inMilliseconds / totalMs).clamp(0.0, 1.0);
          final side = switch (widget.total) {
            DotMatrixTotal.none => null,
            DotMatrixTotal.small => formatMmss(dur),
            DotMatrixTotal.remaining => '−${formatMmss(dur - pos < Duration.zero ? Duration.zero : dur - pos)}',
          };
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SizedBox(
              height: DotMatrixSeek._height,
              child: Row(children: [
                SizedBox(
                  width: _digitsWidth(context, dur),
                  child: Text(
                    formatMmss(pos),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: DotMatrixSeek._digitStyle.copyWith(color: widget.tint),
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
                      child: AnimatedBuilder(
                        animation: _ticker,
                        builder: (context, _) => CustomPaint(
                          size: Size.infinite,
                          painter: _EqualizerPainter(
                            bars: _bars,
                            t: _clock.elapsedMicroseconds / 1e6,
                            progress: frac,
                          ),
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

double _eqBarValue(_EqBar b, double t) {
  final s = 0.55 + 0.45 * math.sin(2 * math.pi * (t * b.speed + b.phase));
  return (b.envelope * s).clamp(0.12, 1.0);
}

class _EqualizerPainter extends CustomPainter {
  const _EqualizerPainter({required this.bars, required this.t, required this.progress});

  final List<_EqBar> bars;
  final double t;
  final double progress;

  // Зоны по высоте КАЖДОГО столбика — лайм самая широкая (низ), красная
  // только на самом верху, как на реальных аппаратных индикаторах.
  static const _greyFrac = 0.55;
  static const _blueFrac = 0.35;
  static const _blue = Color(0xFF4DA3FF);
  static const _red = Color(0xFFFF4D4D);
  static final _dim = Colors.white.withValues(alpha: 0.16);

  void _segmentedBar(Canvas c, double x, double width, double barTopY, double baseY, bool played) {
    if (!played) {
      c.drawRect(Rect.fromLTWH(x, barTopY, width, baseY - barTopY), Paint()..color = _dim);
      return;
    }
    final h = baseY - barTopY;
    final greyH = h * _greyFrac;
    final blueH = h * _blueFrac;
    c.drawRect(Rect.fromLTWH(x, baseY - greyH, width, greyH), Paint()..color = Afisha.lime);
    if (h > greyH) {
      final blueTop = math.max(barTopY, baseY - greyH - blueH);
      c.drawRect(Rect.fromLTWH(x, blueTop, width, (baseY - greyH) - blueTop), Paint()..color = _blue);
    }
    if (h > greyH + blueH) {
      c.drawRect(Rect.fromLTWH(x, barTopY, width, (baseY - greyH - blueH) - barTopY), Paint()..color = _red);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final n = bars.length;
    final gap = size.width / n;
    final w = math.max(1.2, gap * 0.5);
    for (var i = 0; i < n; i++) {
      final v = _eqBarValue(bars[i], t);
      final h = (size.height * v).clamp(3.0, size.height);
      final x = i * gap + (gap - w) / 2;
      _segmentedBar(canvas, x, w, size.height - h, size.height, (i + 0.5) / n <= progress);
    }
  }

  @override
  bool shouldRepaint(covariant _EqualizerPainter old) => true;
}
