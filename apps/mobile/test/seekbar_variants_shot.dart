// 10 вариантов полосы перемотки плеера вместо волны — картинки из НАСТОЯЩЕЙ
// отрисовки Flutter (CustomPainter, шрифты и цвета приложения), не из головы.
// Не проверка логики. Запуск:
//   flutter test --update-goldens test/seekbar_variants_shot.dart
// Картинки: test/goldens/seekbar_variants_1.png … _3.png
//
// Alex TG 19.09.2026: «а какие ещё варианты кроме волны можешь предложить?
// 10 вариантов нарисуй». Форма волны на картинках — ОБРАЗЕЦ (сервер дома
// с этого компьютера не отвечал), не конкретная песня. Позиция 1:12 из 4:33 —
// как на остальных картинках плеера.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/theme.dart';

const _p = 72 / 273; // 1:12 из 4:33
const _nowSec = 72.0;
const _totalSec = 273.0;

/// Образец «формы громкости»: тихое начало, куплет, громкий припев, спад,
/// с неровностями, как у настоящей песни (фиксированный генератор — картинка
/// не меняется от запуска к запуску).
final List<double> _amps = () {
  final rnd = math.Random(11);
  return List<double>.generate(64, (i) {
    final t = i / 63;
    final env = t < 0.08
        ? 0.25 + t * 3
        : t < 0.45
            ? 0.5
            : t < 0.7
                ? 0.85
                : t < 0.92
                    ? 0.55
                    : 0.55 - (t - 0.92) * 4;
    return (env + (rnd.nextDouble() - 0.5) * 0.3).clamp(0.12, 1.0);
  });
}();

const _tintA = Color(0xFFFF5C93); // пример цвета обложки
const _tintB = Color(0xFFFFB454);

Color get _lime => Afisha.lime;
Color get _dim => Colors.white.withValues(alpha: 0.16);

Paint _stroke(Color c, double w) => Paint()
  ..color = c
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round;

class _P extends CustomPainter {
  _P(this.f);
  final void Function(Canvas, Size) f;
  @override
  void paint(Canvas canvas, Size size) => f(canvas, size);
  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

Widget _paint(void Function(Canvas, Size) f) => CustomPaint(painter: _P(f), size: Size.infinite);

// ── варианты ────────────────────────────────────────────────────────────

// 0. Сейчас: 64 столбика по данным сервера (копия _WavePainter из player_view.dart).
void _now(Canvas c, Size s) {
  final n = _amps.length;
  final gap = s.width / n;
  final mid = s.height / 2;
  for (var i = 0; i < n; i++) {
    final x = i * gap + gap / 2;
    final h = (s.height * _amps[i]).clamp(3.0, s.height);
    c.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2),
        _stroke((i / n) <= _p ? _lime : _dim, gap * 0.55));
  }
  final hx = (_p * s.width).clamp(1.0, s.width - 1);
  c.drawLine(Offset(hx, 0), Offset(hx, s.height), _stroke(_lime.withValues(alpha: 0.9), 2));
}

// 1. Тонкая линия с точкой.
void _thin(Canvas c, Size s) {
  final y = s.height / 2;
  final hx = _p * s.width;
  c.drawLine(Offset(0, y), Offset(s.width, y), _stroke(_dim, 3));
  c.drawLine(Offset(0, y), Offset(hx, y), _stroke(_lime, 3));
  c.drawCircle(Offset(hx, y), 7, Paint()..color = _lime);
}

// 2. Толстая капсула.
void _capsule(Canvas c, Size s) {
  final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, s.height / 2 - 8, s.width, 16), const Radius.circular(8));
  c.drawRRect(r, Paint()..color = _dim);
  c.save();
  c.clipRect(Rect.fromLTWH(0, 0, _p * s.width, s.height));
  c.drawRRect(r, Paint()..color = _lime);
  c.restore();
}

// 3. Сегменты («батарейка»), 24 штуки.
void _segments(Canvas c, Size s) {
  const n = 24;
  const gap = 4.0;
  final w = (s.width - gap * (n - 1)) / n;
  for (var i = 0; i < n; i++) {
    final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * (w + gap), s.height / 2 - 9, w, 18), const Radius.circular(4));
    c.drawRRect(r, Paint()..color = (i + 0.5) / n <= _p ? _lime : _dim);
  }
}

// 4. Точки, 48 штук, текущая крупнее.
void _dots(Canvas c, Size s) {
  const n = 48;
  final y = s.height / 2;
  final cur = (_p * (n - 1)).round();
  for (var i = 0; i < n; i++) {
    final x = 4 + i * (s.width - 8) / (n - 1);
    final played = i <= cur;
    c.drawCircle(Offset(x, y), i == cur ? 6.5 : 3, Paint()..color = played ? _lime : _dim);
  }
}

// 5. Линейка с делениями: деление = 3 секунды, крупное = каждые 30.
void _ruler(Canvas c, Size s) {
  const n = 91;
  final mid = s.height / 2;
  final hx = _p * s.width;
  for (var i = 0; i < n; i++) {
    final x = i * s.width / (n - 1);
    final major = i % 10 == 0;
    final h = major ? 24.0 : 11.0;
    c.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2),
        _stroke(x <= hx ? _lime.withValues(alpha: 0.75) : _dim, major ? 2 : 1.5));
  }
  c.drawLine(Offset(hx, 2), Offset(hx, s.height - 2), _stroke(_lime, 3));
}

// 6. Светящаяся линия цвета обложки.
void _glow(Canvas c, Size s) {
  final y = s.height / 2;
  final hx = _p * s.width;
  c.drawLine(Offset(0, y), Offset(s.width, y), _stroke(_dim, 4));
  final line = _stroke(_tintA, 4)
    ..shader = const LinearGradient(colors: [_tintA, _tintB])
        .createShader(Rect.fromLTWH(0, 0, hx, 1));
  c.drawLine(Offset(0, y), Offset(hx, y), line);
  c.drawCircle(
      Offset(hx, y),
      13,
      Paint()
        ..color = _tintB.withValues(alpha: 0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9));
  c.drawCircle(Offset(hx, y), 6.5, Paint()..color = Colors.white);
}

// 7. Кольцо вокруг кнопки «плей».
void _ring(Canvas c, Size s) {
  final ctr = s.center(Offset.zero);
  final r = s.shortestSide / 2 - 5;
  c.drawCircle(ctr, r, Paint()
    ..color = _dim
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6);
  final sweep = 2 * math.pi * _p;
  c.drawArc(Rect.fromCircle(center: ctr, radius: r), -math.pi / 2, sweep, false, Paint()
    ..color = _lime
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6
    ..strokeCap = StrokeCap.round);
  final a = -math.pi / 2 + sweep;
  c.drawCircle(ctr + Offset(math.cos(a), math.sin(a)) * r, 7, Paint()..color = _lime);
}

String _mmss(double sec) => '${sec ~/ 60}:${(sec.toInt() % 60).toString().padLeft(2, '0')}';

// 8. Лента времени: курсор стоит по центру, лента едет под ним.
void _ribbon(Canvas c, Size s) {
  const pxPerSec = 2.6;
  final mid = s.height / 2 + 4;
  final cx = s.width / 2;
  for (var t = 0.0; t <= _totalSec; t += 5) {
    final x = cx + (t - _nowSec) * pxPerSec;
    if (x < 0 || x > s.width) continue;
    final major = t % 30 == 0;
    final h = major ? 22.0 : 10.0;
    c.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2),
        _stroke(t <= _nowSec ? _lime.withValues(alpha: 0.75) : _dim, major ? 2 : 1.5));
    if (major) {
      final tp = TextPainter(
        text: TextSpan(
            text: _mmss(t),
            style: const TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'Inter')),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(x - tp.width / 2, mid + 14));
    }
  }
  c.drawLine(Offset(cx, 0), Offset(cx, s.height - 12), _stroke(_lime, 3));
}

// 9. Крупные столбики: 16 штук из тех же данных.
void _bigBars(Canvas c, Size s) {
  const n = 16;
  final gap = s.width / n;
  final mid = s.height / 2;
  for (var i = 0; i < n; i++) {
    final v = _amps.sublist(i * 4, i * 4 + 4).reduce((a, b) => a + b) / 4;
    final h = (s.height * v).clamp(8.0, s.height);
    final x = i * gap + gap / 2;
    c.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2),
        _stroke((i + 0.5) / n <= _p ? _lime : _dim, gap * 0.62));
  }
}

// 10. Плавный «холм» громкости.
Path _smooth(List<Offset> pts) {
  final p = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (var i = 1; i < pts.length - 1; i++) {
    final m = (pts[i] + pts[i + 1]) / 2;
    p.quadraticBezierTo(pts[i].dx, pts[i].dy, m.dx, m.dy);
  }
  return p..lineTo(pts.last.dx, pts.last.dy);
}

void _hill(Canvas c, Size s) {
  final n = _amps.length;
  final mid = s.height / 2;
  final top = [for (var i = 0; i < n; i++) Offset(i * s.width / (n - 1), mid - s.height / 2 * _amps[i] * 0.95)];
  final bot = [for (final o in top) Offset(o.dx, 2 * mid - o.dy)];
  Path area(List<Offset> pts) => _smooth(pts)
    ..lineTo(pts.last.dx, mid)
    ..lineTo(pts.first.dx, mid)
    ..close();
  final shape = Path()
    ..addPath(area(top), Offset.zero)
    ..addPath(area(bot), Offset.zero);
  c.drawPath(shape, Paint()..color = _dim);
  c.save();
  c.clipRect(Rect.fromLTWH(0, 0, _p * s.width, s.height));
  c.drawPath(shape, Paint()..color = _lime);
  c.restore();
  final hx = _p * s.width;
  c.drawLine(Offset(hx, 0), Offset(hx, s.height), _stroke(_lime, 2));
}

// ── набор 2 (11-20): идеи из открытых подборок дизайна ───────────────────
// Alex TG 19.09.2026: «а ещё варианты? может в пинтерест посмотришь?».
// Pinterest инструменты не открывают; смотрели открытые галереи (Collect UI),
// подборки про полосы прогресса и описание «волнистой» полосы Android 13+ /
// Material 3 Expressive. Здесь свои отрисовки этих ИДЕЙ, не копии чужих работ.

// 11. Волнистая линия: играет — колышется, пауза — ровная (тут «в движении»).
void _wavy(Canvas c, Size s) {
  final y = s.height / 2;
  final hx = _p * s.width;
  double wy(double x) => y + 5.5 * math.sin(x / 26 * 2 * math.pi) * (x < 18 ? x / 18 : 1);
  c.drawLine(Offset(hx, y), Offset(s.width, y), _stroke(_dim, 4));
  final path = Path()..moveTo(0, y);
  for (var x = 0.0; x <= hx; x += 1) {
    path.lineTo(x, wy(x));
  }
  c.drawPath(
      path,
      Paint()
        ..color = _lime
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round);
  c.drawCircle(Offset(hx, wy(hx)), 7, Paint()..color = _lime);
}

const _coverGrey = Color(0xFF1F1F1F);

// 12. Вода: уровень воды на обложке = место в песне.
void _water(Canvas c, Size s) {
  final side = math.min(s.width, s.height) - 6;
  final rect = Rect.fromCenter(center: s.center(Offset.zero), width: side, height: side);
  final rr = RRect.fromRectAndRadius(rect, const Radius.circular(20));
  c.drawRRect(rr, Paint()..color = _coverGrey);
  c.save();
  c.clipRRect(rr);
  final level = rect.bottom - rect.height * _p;
  final path = Path()
    ..moveTo(rect.left, rect.bottom)
    ..lineTo(rect.left, level);
  for (var x = 0.0; x <= rect.width; x += 2) {
    path.lineTo(rect.left + x, level + 3.5 * math.sin(x / 20 * 2 * math.pi));
  }
  path
    ..lineTo(rect.right, rect.bottom)
    ..close();
  c.drawPath(path, Paint()..color = _lime.withValues(alpha: 0.88));
  c.restore();
}

// 13. Рамка обложки: прогресс бежит по краю обложки по часовой стрелке.
void _frame(Canvas c, Size s) {
  final side = math.min(s.width, s.height) - 10;
  const r = 22.0;
  final ctr = s.center(Offset.zero);
  final l = ctr.dx - side / 2, t = ctr.dy - side / 2, rt = l + side, b = t + side;
  c.drawRRect(RRect.fromLTRBR(l + 5, t + 5, rt - 5, b - 5, const Radius.circular(r - 5)),
      Paint()..color = _coverGrey);
  final path = Path()
    ..moveTo(ctr.dx, t)
    ..lineTo(rt - r, t)
    ..arcToPoint(Offset(rt, t + r), radius: const Radius.circular(r))
    ..lineTo(rt, b - r)
    ..arcToPoint(Offset(rt - r, b), radius: const Radius.circular(r))
    ..lineTo(l + r, b)
    ..arcToPoint(Offset(l, b - r), radius: const Radius.circular(r))
    ..lineTo(l, t + r)
    ..arcToPoint(Offset(l + r, t), radius: const Radius.circular(r))
    ..lineTo(ctr.dx, t);
  Paint edge(Color col) => Paint()
    ..color = col
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5
    ..strokeCap = StrokeCap.round;
  c.drawPath(path, edge(_dim));
  final m = path.computeMetrics().first;
  c.drawPath(m.extractPath(0, m.length * _p), edge(_lime));
  c.drawCircle(m.getTangentForOffset(m.length * _p)!.position, 7.5, Paint()..color = _lime);
}

// 14. Кнопка «плей» сама заполняется.
void _fillButton(Canvas c, Size s) {
  final rr = RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(28));
  c.drawRRect(rr, Paint()..color = const Color(0xFF2A2A2A));
  c.save();
  c.clipRRect(rr);
  c.drawRect(Rect.fromLTWH(0, 0, s.width * _p, s.height), Paint()..color = _lime);
  c.restore();
}

// 16. Дуга-«спидометр».
void _arc(Canvas c, Size s) {
  final r = math.min(s.width / 2 - 14, s.height - 16);
  final ctr = Offset(s.width / 2, s.height - 8);
  final rect = Rect.fromCircle(center: ctr, radius: r);
  Paint arcPaint(Color col) => Paint()
    ..color = col
    ..style = PaintingStyle.stroke
    ..strokeWidth = 8
    ..strokeCap = StrokeCap.round;
  c.drawArc(rect, math.pi, math.pi, false, arcPaint(_dim));
  c.drawArc(rect, math.pi, math.pi * _p, false, arcPaint(_lime));
  final a = math.pi + math.pi * _p;
  c.drawCircle(ctr + Offset(math.cos(a), math.sin(a)) * r, 9.5, Paint()..color = _lime);
}

// 17. Пластинка с рычагом: игла едет от края к центру.
void _vinyl(Canvas c, Size s) {
  final r = math.min(s.height / 2 - 6, 66.0);
  final ctr = Offset(s.width / 2 - 34, s.height / 2);
  c.drawCircle(ctr, r, Paint()..color = const Color(0xFF141414));
  c.drawCircle(
      ctr,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.16)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
  for (var g = r - 8; g > 26; g -= 6) {
    c.drawCircle(
        ctr,
        g,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.06)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }
  c.drawCircle(ctr, 19, Paint()..color = _lime);
  c.drawCircle(ctr, 3.5, Paint()..color = Colors.black);
  final pivot = ctr + Offset(r + 46, -r + 4);
  const ang = -math.pi * 0.3;
  final tipR = (r - 6) - ((r - 6) - 27) * _p;
  final tip = ctr + Offset(math.cos(ang), math.sin(ang)) * tipR;
  c.drawLine(pivot, tip, _stroke(Colors.white70, 4));
  c.drawCircle(pivot, 9, Paint()..color = Colors.white24);
  c.drawCircle(pivot, 4, Paint()..color = Colors.white70);
  c.drawCircle(tip, 4.5, Paint()..color = _lime);
}

// 18. Кассета: слева ленты убывает, справа прибывает.
void _cassette(Canvas c, Size s) {
  final w = math.min(s.width - 40, 264.0);
  const h = 108.0;
  final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: s.center(Offset.zero), width: w, height: h), const Radius.circular(12));
  c.drawRRect(body, Paint()..color = const Color(0xFF232323));
  c.drawRRect(
      body,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.16)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
  final win = Rect.fromCenter(center: body.center + const Offset(0, -8), width: w * 0.74, height: 52);
  c.drawRRect(RRect.fromRectAndRadius(win, const Radius.circular(26)), Paint()..color = Colors.black);
  final lc = Offset(win.left + 30, win.center.dy);
  final rc = Offset(win.right - 30, win.center.dy);
  c.drawCircle(lc, 25 - 13 * _p, Paint()..color = Colors.white.withValues(alpha: 0.3));
  c.drawCircle(rc, 12 + 13 * _p, Paint()..color = _lime);
  for (final ctr in [lc, rc]) {
    c.drawCircle(ctr, 10, Paint()..color = Colors.white);
    for (var k = 0; k < 6; k++) {
      final a = k * math.pi / 3;
      c.drawLine(ctr + Offset(math.cos(a), math.sin(a)) * 4, ctr + Offset(math.cos(a), math.sin(a)) * 9,
          _stroke(Colors.black, 1.6));
    }
  }
  c.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: body.center + const Offset(0, 36), width: w * 0.46, height: 15),
          const Radius.circular(4)),
      Paint()..color = Colors.white.withValues(alpha: 0.13));
}

// 19. Точечная матрица (как ЖК-табло): пять рядов по 40 квадратиков.
void _matrix(Canvas c, Size s) {
  const cols = 40, rows = 5;
  final cw = s.width / cols;
  final rh = s.height / rows;
  final d = math.min(cw, rh) * 0.64;
  for (var i = 0; i < cols; i++) {
    for (var j = 0; j < rows; j++) {
      final ctr = Offset(i * cw + cw / 2, j * rh + rh / 2);
      c.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: ctr, width: d, height: d), Radius.circular(d * 0.25)),
          Paint()..color = (i + 0.5) / cols <= _p ? _lime : _dim);
    }
  }
}

// 20. Вертикальная полоса вдоль правого края экрана (вести большим пальцем).
void _edge(Canvas c, Size s) {
  final body = RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(22));
  c.drawRRect(body, Paint()..color = const Color(0xFF141414));
  c.drawRRect(
      body.deflate(1),
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
  final cover = s.width - 16 - 32;
  c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(16, 34, cover, cover), const Radius.circular(10)),
      Paint()..color = _coverGrey);
  final x = s.width - 15;
  final top = 26.0;
  final bot = s.height - 26;
  c.drawLine(Offset(x, top), Offset(x, bot), _stroke(_dim, 5));
  final hy = top + (bot - top) * _p;
  c.drawLine(Offset(x, top), Offset(x, hy), _stroke(_lime, 5));
  c.drawCircle(Offset(x, hy), 8, Paint()..color = _lime);
}

Widget _timesAround(Widget middle, {double gap = 22}) => Center(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Text('1:12', style: TextStyle(color: Colors.white54, fontSize: 12)),
        SizedBox(width: gap),
        middle,
        SizedBox(width: gap),
        const Text('4:33', style: TextStyle(color: Colors.white54, fontSize: 12)),
      ]),
    );

// ── сборка страниц ──────────────────────────────────────────────────────

class _V {
  const _V(this.no, this.title, this.note, this.needsServer, this.strip,
      {this.stripH = 48, this.times = true});
  final String no;
  final String title;
  final String note;
  final bool needsServer;
  final Widget Function() strip;
  final double stripH;
  final bool times;
}

final _variants = <_V>[
  _V('•', 'Сейчас: волна', 'для сравнения; 64 столбика, форма берётся с сервера', true,
      () => _paint(_now), stripH: 52),
  _V('1', 'Тонкая линия с точкой', 'как у большинства плееров; ничего лишнего', false, () => _paint(_thin)),
  _V('2', 'Толстая капсула', 'крупная, легко попасть пальцем и вести', false, () => _paint(_capsule)),
  _V('3', 'Сегменты («батарейка»)', '24 деления; видно «примерно где в песне»', false, () => _paint(_segments)),
  _V('4', 'Точки', '48 точек, текущая крупнее; мягкий, игровой вид', false, () => _paint(_dots)),
  _V('5', 'Линейка с делениями', 'деление = 3 секунды, крупное = 30; видно масштаб времени', false, () => _paint(_ruler)),
  _V('6', 'Светящаяся линия цвета обложки', 'цвет и свечение от обложки (здесь пример цвета)', false, () => _paint(_glow)),
  _V('7', 'Кольцо вокруг кнопки «плей»', 'полоса уходит вокруг кнопки; освобождает место внизу', false,
      () => Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('1:12', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(width: 22),
              SizedBox(
                width: 108,
                height: 108,
                child: Stack(alignment: Alignment.center, children: [
                  SizedBox.expand(child: _paint(_ring)),
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(color: _lime, borderRadius: BorderRadius.circular(18)),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.black, size: 36),
                  ),
                ]),
              ),
              const SizedBox(width: 22),
              const Text('4:33', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
      stripH: 108, times: false),
  _V('8', 'Лента времени', 'курсор стоит, лента едет под ним; точная, но далеко перематывать долго', false,
      () => _paint(_ribbon), stripH: 58),
  _V('9', 'Крупные столбики', '16 штук из тех же данных сервера; спокойнее, чем 64', true, () => _paint(_bigBars)),
  _V('10', 'Плавный «холм» громкости', 'гладкий силуэт по данным сервера', true, () => _paint(_hill), stripH: 52),
];

final _variants2 = <_V>[
  _V('11', 'Волнистая линия', 'играет — колышется, на паузе ровная (тут «в движении»); модно у Android 13+', false,
      () => _paint(_wavy), stripH: 40),
  _V('12', 'Вода на обложке', 'уровень воды поднимается по мере песни; вести пальцем вверх-вниз', false,
      () => _paint(_water), stripH: 126, times: false),
  _V('13', 'Рамка обложки', 'полоска бежит по краю обложки по кругу; экран без лишних полос', false,
      () => _paint(_frame), stripH: 126, times: false),
  _V('14', 'Кнопка «плей» заполняется', 'сама кнопка = полоса; отдельной полосы нет вообще', false,
      () => _timesAround(SizedBox(
            width: 92,
            height: 92,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(child: _paint(_fillButton)),
              const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 46),
            ]),
          )),
      stripH: 92, times: false),
  _V('15', 'Название заливается цветом', 'как в караоке: название закрашивается по мере песни; вести пальцем по названию', false,
      () => Center(
            child: ShaderMask(
              shaderCallback: (r) => LinearGradient(
                colors: [_lime, _lime, Colors.white38, Colors.white38],
                stops: const [0, _p, _p, 1],
              ).createShader(r),
              blendMode: BlendMode.srcIn,
              child: const Text('Спокойная ночь',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
      stripH: 46),
  _V('16', 'Дуга-«спидометр»', 'полукруг под обложкой; ведёшь по дуге', false, () => _paint(_arc), stripH: 104),
  _V('17', 'Пластинка с рычагом', 'игла едет от края пластинки к центру; кому нравится «винил»', false,
      () => _paint(_vinyl), stripH: 146, times: false),
  _V('18', 'Кассета', 'слева ленты убывает, справа прибывает; ретро', false, () => _paint(_cassette),
      stripH: 122, times: false),
  _V('19', 'Точечная матрица + цифры', 'как ЖК-табло: крупное время и точки-квадратики', false,
      () => Row(children: [
            const Text('1:12',
                style: TextStyle(
                    color: Color(0xFFB0FF00),
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()])),
            const SizedBox(width: 14),
            Expanded(child: _paint(_matrix)),
          ]),
      stripH: 40, times: false),
  _V('20', 'Вертикальная полоса у края', 'вдоль правого края экрана; вести большим пальцем одной рукой', false,
      () => Center(
            child: SizedBox(width: 132, height: 204, child: _paint(_edge)),
          ),
      stripH: 204, times: false),
];

Widget _row(_V v) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: v.no == '•' ? Colors.white24 : _lime, borderRadius: BorderRadius.circular(6)),
            child: Text(v.no,
                style: TextStyle(
                    color: v.no == '•' ? Colors.white : Colors.black,
                    fontWeight: FontWeight.w700,
                    fontSize: 12)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(v.title,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
          ),
          Text(v.needsServer ? 'нужны данные сервера' : 'без сервера',
              style: TextStyle(
                  color: v.needsServer ? const Color(0xFFFFB454) : _lime.withValues(alpha: 0.9),
                  fontSize: 10)),
        ]),
        const SizedBox(height: 3),
        Text(v.note, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        const SizedBox(height: 10),
        SizedBox(height: v.stripH, width: double.infinity, child: v.strip()),
        if (v.times)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('1:12', style: TextStyle(color: Colors.white38, fontSize: 10)),
              Text('4:33', style: TextStyle(color: Colors.white38, fontSize: 10)),
            ]),
          ),
        const SizedBox(height: 10),
        Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
      ]),
    );

Widget _page(List<_V> vs, Key key) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: Scaffold(
        backgroundColor: Afisha.bg,
        body: Align(
          alignment: Alignment.topCenter,
          child: Column(key: key, mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 8),
            for (final v in vs) _row(v),
            const SizedBox(height: 4),
          ]),
        ),
      ),
    );

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

  final pages = <List<_V>>[
    _variants.sublist(0, 4), // сейчас + 1-3
    _variants.sublist(4, 8), // 4-7
    _variants.sublist(8), // 8-10
    _variants2.sublist(0, 3), // 11-13
    _variants2.sublist(3, 6), // 14-16
    _variants2.sublist(6, 8), // 17-18
    _variants2.sublist(8), // 19-20
  ];
  for (var i = 0; i < pages.length; i++) {
    testWidgets('варианты полосы перемотки — страница ${i + 1}', (t) async {
      final key = GlobalKey();
      await t.binding.setSurfaceSize(const Size(400, 1600));
      await t.pumpWidget(_page(pages[i], key));
      await t.pump();
      // сначала меряем, сколько места реально заняли строки, потом режем
      // картинку ровно по ним
      final h = t.getSize(find.byKey(key)).height + 16;
      await t.binding.setSurfaceSize(Size(400, h));
      await t.pumpWidget(_page(pages[i], GlobalKey()));
      await t.pump();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/seekbar_variants_${i + 1}.png'));
    });
  }
}
