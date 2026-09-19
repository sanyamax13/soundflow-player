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
