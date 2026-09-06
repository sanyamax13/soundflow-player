// Одноразовый рендер вариантов НОВОГО экрана плеера в PNG — чтобы Alex
// посмотрел их глазами и выбрал направление ДО реализации (задача TG
// 18568–18572: «плеер из будущего», анимации, тап обложки, свайпы, фишки
// One UI 8.5 и последнего Android). Golden-файлы тут — просто картинки, не
// проверка логики. Запуск:
//   flutter test --update-goldens test/player_mockups.dart
// Картинки: test/goldens/player_mock_*.png
//
// Виджеты настоящие (тема Afisha, шрифт Inter), обложка — синтетическая
// (градиент + пятна), данные выдуманы. Движение на статичной картинке не
// видно — его показываем отдельным видео на выбранном варианте.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/theme.dart';

// ── синтетическая «обложка альбома» ──────────────────────────────────────────
class _CoverPainter extends CustomPainter {
  const _CoverPainter(this.seed);
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    Color pick() => HSLColor.fromAHSL(
          1,
          rnd.nextDouble() * 360,
          0.55 + rnd.nextDouble() * 0.3,
          0.35 + rnd.nextDouble() * 0.3,
        ).toColor();

    final bg = pick();
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    for (var i = 0; i < 5; i++) {
      final c = pick();
      final center = Offset(
        rnd.nextDouble() * size.width,
        rnd.nextDouble() * size.height,
      );
      final r = size.width * (0.25 + rnd.nextDouble() * 0.5);
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..color = c.withValues(alpha: 0.55)
          ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 40),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CoverPainter old) => old.seed != seed;
}

Color _coverTint(int seed) => HSLColor.fromAHSL(
      1,
      math.Random(seed).nextDouble() * 360,
      0.6,
      0.42,
    ).toColor();

Widget _cover(int seed, double size, {double radius = 24}) => ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _CoverPainter(seed)),
      ),
    );

Widget _blurBackdrop(int seed) => Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60),
          child: CustomPaint(painter: _CoverPainter(seed)),
        ),
        Container(color: Colors.black.withValues(alpha: 0.45)),
      ],
    );

const _seed = 7; // одна и та же «обложка» во всех трёх макетах
const _title = 'Спокойная ночь';
const _artist = 'Кино';

// ── МАКЕТ 1 — «Тихо»: минимум, всё на жест ───────────────────────────────────
class MockCalm extends StatelessWidget {
  const MockCalm({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Afisha.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _blurBackdrop(_seed),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
                stops: [0.45, 1.0],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 14),
                Text('очередь ↑     ↓ закрыть',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 12,
                        letterSpacing: 0.5)),
                const Spacer(),
                Center(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 60,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: _cover(_seed, 300, radius: 30),
                  ),
                ),
                const SizedBox(height: 44),
                const Text(_title,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 27,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 0.3)),
                const SizedBox(height: 8),
                Text(_artist,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 15)),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.skip_previous,
                        color: Colors.white.withValues(alpha: 0.8), size: 34),
                    const SizedBox(width: 52),
                    Icon(Icons.pause_circle_outline,
                        color: Colors.white, size: 76),
                    const SizedBox(width: 52),
                    Icon(Icons.skip_next,
                        color: Colors.white.withValues(alpha: 0.8), size: 34),
                  ],
                ),
                const SizedBox(height: 34),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Row(
                    children: [
                      Text('1:12',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 11)),
                      Expanded(
                        child: Container(
                          height: 2,
                          margin: const EdgeInsets.symmetric(horizontal: 10),
                          color: Colors.white24,
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: 0.35,
                            child: Container(color: Colors.white),
                          ),
                        ),
                      ),
                      Text('4:33',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── МАКЕТ 2 — «Живая»: цвет из обложки, крупные пружинистые кнопки ────────────
class MockVivid extends StatelessWidget {
  const MockVivid({super.key});
  @override
  Widget build(BuildContext context) {
    final tint = _coverTint(_seed);
    return Scaffold(
      backgroundColor: Afisha.bg,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              tint.withValues(alpha: 0.85),
              Colors.black,
              Colors.black,
            ],
            stops: const [0.0, 0.6, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(width: 8),
                  Icon(Icons.keyboard_arrow_down,
                      color: Colors.white.withValues(alpha: 0.9)),
                  const Spacer(),
                  Text('ПОТОК',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                          letterSpacing: 2)),
                  const Spacer(),
                  Icon(Icons.more_horiz,
                      color: Colors.white.withValues(alpha: 0.9)),
                  const SizedBox(width: 8),
                ],
              ),
              const SizedBox(height: 26),
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                          color: tint.withValues(alpha: 0.6),
                          blurRadius: 70,
                          spreadRadius: 2),
                    ],
                  ),
                  child: _cover(_seed, 320, radius: 24),
                ),
              ),
              const SizedBox(height: 34),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 28),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700)),
                          SizedBox(height: 4),
                          Text(_artist,
                              style:
                                  TextStyle(color: Colors.white70, fontSize: 15)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              // реакция вкуса
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 28),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _tasteChip(Icons.thumb_down_alt_outlined, 'меньше', false),
                    _tasteChip(Icons.favorite, 'нравится', true),
                    _tasteChip(Icons.thumb_up_alt_outlined, 'больше', false),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 26),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: 0.35,
                        minHeight: 6,
                        backgroundColor: Colors.white.withValues(alpha: 0.18),
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(Afisha.lime),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('1:12',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 12)),
                        Text('4:33',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.shuffle, color: Afisha.lime, size: 22),
                  const SizedBox(width: 22),
                  const Icon(Icons.skip_previous, color: Colors.white, size: 38),
                  const SizedBox(width: 16),
                  Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      color: Afisha.lime,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Icon(Icons.pause,
                        color: Colors.black, size: 38),
                  ),
                  const SizedBox(width: 16),
                  const Icon(Icons.skip_next, color: Colors.white, size: 38),
                  const SizedBox(width: 22),
                  const Icon(Icons.graphic_eq,
                      color: Colors.white54, size: 22),
                ],
              ),
              const SizedBox(height: 30),
              // «карточка очереди» выглядывает снизу (стиль Now Bar)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text('ДАЛЬШE',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 11,
                                letterSpacing: 1.5)),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text('Группа крови — Кино',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white, fontSize: 14)),
                        ),
                        const Icon(Icons.keyboard_arrow_up,
                            color: Colors.white54),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tasteChip(IconData icon, String label, bool active) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Afisha.lime.withValues(alpha: 0.15) : null,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 19, color: active ? Afisha.lime : Colors.white70),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: active ? Afisha.lime : Colors.white70,
                    fontSize: 12.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
          ],
        ),
      );
}

// ── МАКЕТ 3 — «Карточки»: колода обложек, всё свайпом ────────────────────────
class MockDeck extends StatelessWidget {
  const MockDeck({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Afisha.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _blurBackdrop(_seed),
          Container(color: Colors.black.withValues(alpha: 0.35)),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 16),
                Text('СВАЙП: ← дальше   → назад   ↑ в любимое   ↓ не нравится',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 10.5,
                        letterSpacing: 0.3)),
                const SizedBox(height: 28),
                Expanded(
                  child: Center(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Transform.translate(
                          offset: const Offset(-150, 0),
                          child: Transform.scale(
                            scale: 0.82,
                            child: Opacity(
                                opacity: 0.5,
                                child: _cover(_seed + 1, 260, radius: 26)),
                          ),
                        ),
                        Transform.translate(
                          offset: const Offset(150, 0),
                          child: Transform.scale(
                            scale: 0.82,
                            child: Opacity(
                                opacity: 0.5,
                                child: _cover(_seed + 2, 260, radius: 26)),
                          ),
                        ),
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  blurRadius: 50,
                                  spreadRadius: 2),
                            ],
                          ),
                          child: _cover(_seed, 300, radius: 28),
                        ),
                        Positioned(
                          left: 8,
                          child: Icon(Icons.chevron_left,
                              color: Colors.white.withValues(alpha: 0.35),
                              size: 40),
                        ),
                        Positioned(
                          right: 8,
                          child: Icon(Icons.chevron_right,
                              color: Colors.white.withValues(alpha: 0.35),
                              size: 40),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(_title,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                const Text(_artist,
                    style: TextStyle(color: Colors.white70, fontSize: 15)),
                const SizedBox(height: 22),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Row(
                    children: [
                      const Text('1:12',
                          style:
                              TextStyle(color: Colors.white38, fontSize: 11)),
                      Expanded(
                        child: Container(
                          height: 3,
                          margin: const EdgeInsets.symmetric(horizontal: 10),
                          color: Colors.white24,
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: 0.35,
                            child: Container(color: Afisha.lime),
                          ),
                        ),
                      ),
                      const Text('4:33',
                          style:
                              TextStyle(color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: 72,
                  height: 72,
                  margin: const EdgeInsets.only(bottom: 26),
                  decoration: const BoxDecoration(
                    color: Afisha.lime,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.pause, color: Colors.black, size: 38),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── волновой ползунок перемотки ─────────────────────────────────────────────
class _WavePainter extends CustomPainter {
  const _WavePainter(this.progress, this.played, this.rest);
  final double progress;
  final Color played;
  final Color rest;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(42);
    const n = 58;
    final gap = size.width / n;
    for (var i = 0; i < n; i++) {
      final h = size.height * (0.18 + rnd.nextDouble() * 0.82);
      final x = i * gap + gap / 2;
      final p = Paint()
        ..color = (i / n) <= progress ? played : rest
        ..strokeWidth = gap * 0.55
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.progress != progress;
}

// ── МАКЕТ 4.2 — «Радио-объект»: после разбора внешнего дизайнера ─────────────
// Убрано: ряд «меньше/нравится/больше», двойной свайп-вниз. Лайк = двойной
// тап. Оценка/скрыть/«не хочу эту версию» — в меню по долгому нажатию.
// Волна — тонкая, но с широкой зоной касания. Кнопок минимум и они в нижней
// дуге под большой палец. Обложка — физический объект (радиус 20, лёгкая
// тень, «дышит» на игре). На экране 6 элементов: обложка · название · волна ·
// кнопки · ручка очереди · чип «∞ радио».
class MockBlend extends StatelessWidget {
  const MockBlend({super.key, this.showActions = false});
  final bool showActions;

  @override
  Widget build(BuildContext context) {
    final tint = _coverTint(_seed);
    return Scaffold(
      backgroundColor: Afisha.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // живой фон: размытая обложка тихо плывёт, цвет «дышит» — почти
          // незаметно (20–40 c на цикл в реальном приложении).
          _blurBackdrop(_seed),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  tint.withValues(alpha: 0.4),
                  Colors.black.withValues(alpha: 0.65),
                  Colors.black,
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(width: 8),
                    Icon(Icons.keyboard_arrow_down,
                        color: Colors.white.withValues(alpha: 0.85)),
                    const Spacer(),
                    Text('ПОТОК',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 12,
                            letterSpacing: 2)),
                    const Spacer(),
                    // тихий индикатор радио
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('∞',
                              style: TextStyle(
                                  color: Afisha.lime,
                                  fontSize: 15,
                                  height: 1)),
                          SizedBox(width: 6),
                          Text('радио',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                const Spacer(),
                // обложка — физический объект + (по долгому нажатию) действия
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.5),
                              blurRadius: 40,
                              offset: const Offset(0, 16)),
                          BoxShadow(
                              color: tint.withValues(alpha: 0.35),
                              blurRadius: 80,
                              spreadRadius: 1),
                        ],
                      ),
                      child: _cover(_seed, showActions ? 232 : 284, radius: 20),
                    ),
                    if (showActions) ...[
                      const _RadialAction(
                          dx: -104, dy: -64, icon: Icons.radio, label: 'радио'),
                      const _RadialAction(
                          dx: 104,
                          dy: -64,
                          icon: Icons.tune,
                          label: 'не хочу\nэту версию'),
                      const _RadialAction(
                          dx: -104,
                          dy: 78,
                          icon: Icons.person_off,
                          label: 'скрыть\nисполнителя'),
                      const _RadialAction(
                          dx: 104,
                          dy: 78,
                          icon: Icons.trending_down,
                          label: 'меньше\nтакого'),
                    ],
                  ],
                ),
                const Spacer(),
                // название крупнее, «исполнитель · альбом» мельче
                const Text(_title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('$_artist · «Группа крови»',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 13)),
                const SizedBox(height: 10),
                Text(
                  'тап — пауза · 2 тапа — нравится · вбок — песня · вверх — очередь · долго — меню',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.28), fontSize: 10),
                ),
                const SizedBox(height: 14),
                // волна: видно тонко, нажимать можно на всю высоту (~52 dp)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 34,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: _WavePainter(
                            0.35,
                            tint,
                            Colors.white.withValues(alpha: 0.16),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('1:12',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 11)),
                          Text('4:33',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                // минимум кнопок, в нижней дуге: назад · play · вперёд · лайк
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.skip_previous,
                        color: Colors.white, size: 40),
                    const SizedBox(width: 26),
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Afisha.lime,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: const Icon(Icons.pause,
                          color: Colors.black, size: 34),
                    ),
                    const SizedBox(width: 26),
                    const Icon(Icons.skip_next, color: Colors.white, size: 40),
                    const SizedBox(width: 26),
                    const Icon(Icons.favorite_border,
                        color: Colors.white70, size: 28),
                  ],
                ),
                const SizedBox(height: 18),
                // ручка очереди — тянешь вверх, слой над плеером
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 34,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(Icons.queue_music,
                              color: Colors.white54, size: 18),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text('Дальше: Группа крови — Кино',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: Colors.white, fontSize: 13.5)),
                          ),
                          Text('12',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontSize: 12)),
                          const Icon(Icons.keyboard_arrow_up,
                              color: Colors.white54),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RadialAction extends StatelessWidget {
  const _RadialAction(
      {required this.dx,
      required this.dy,
      required this.icon,
      required this.label});
  final double dx;
  final double dy;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(dx, dy),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 11)),
        ],
      ),
    );
  }
}

Future<void> _shot(WidgetTester t, Widget w, String name) async {
  await t.binding.setSurfaceSize(const Size(400, 860));
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: Afisha.theme(),
    home: w,
  ));
  await t.pumpAndSettle();
  await expectLater(
      find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  setUpAll(() async {
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final f = File('assets/fonts/Inter-$w.ttf');
      if (f.existsSync()) {
        await (FontLoader('Inter')
              ..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer))))
            .load();
      }
    }
    for (final p in [
      r'E:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
      r'E:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    ]) {
      final f = File(p);
      if (f.existsSync()) {
        await (FontLoader('MaterialIcons')
              ..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer))))
            .load();
        break;
      }
    }
  });

  testWidgets('1 — тихо', (t) => _shot(t, const MockCalm(), 'player_mock_1_calm'));
  testWidgets('2 — живая', (t) => _shot(t, const MockVivid(), 'player_mock_2_vivid'));
  testWidgets('3 — карточки', (t) => _shot(t, const MockDeck(), 'player_mock_3_deck'));
  testWidgets('4 — сборка', (t) => _shot(t, const MockBlend(), 'player_mock_4_blend'));
  testWidgets('4б — сборка, действия',
      (t) => _shot(t, const MockBlend(showActions: true), 'player_mock_4b_actions'));
}
