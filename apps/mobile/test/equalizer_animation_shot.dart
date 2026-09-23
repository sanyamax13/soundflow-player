// Анимация вариантов 9/10/11 (см. equalizer_variants_shot.dart) — Alex
// попросил голосовым увидеть их в движении, не статичной картинкой:
// «покажи мне анимацию троих последних примеров, то есть это 9, 10 и 11».
// Реального звука нет — высота каждого столбика гладко колеблется во
// времени (своя скорость/фаза на столбик, фиксированный seed), имитируя
// пляшущий эквалайзер. Только эскиз стиля, dot_matrix_seek.dart/
// player_view.dart не трогает.
//
// Кадры пишутся как обычные PNG на диск (НЕ goldens), потом снаружи
// (ffmpeg) собираются в mp4 — см. отчёт сессии. Захват кадра — ТОЛЬКО
// через tester.runAsync(), иначе toImage() виснет насмерть под FakeAsync.
//
// Запуск: flutter test test/equalizer_animation_shot.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/theme.dart';

const _p = 72 / 273; // 1:12 из 4:33

const _digitStyle = TextStyle(
  fontSize: 24,
  fontWeight: FontWeight.w600,
  height: 1,
  fontFeatures: [FontFeature.tabularFigures()],
);

const _segGrey = Color(0xFF7A7A85);
const _segBlue = Color(0xFF4DA3FF);
const _segRed = Color(0xFFFF4D4D);
const _segGreyFrac = 0.55;
const _segBlueFrac = 0.35;
Color get _dim => Colors.white.withValues(alpha: 0.16);

class _AnimBar {
  const _AnimBar(this.envelope, this.speed, this.phase);
  final double envelope;
  final double speed;
  final double phase;
}

List<_AnimBar> _animBars(int n, int seed) {
  final rnd = math.Random(seed);
  return List<_AnimBar>.generate(n, (_) {
    final env = 0.18 + rnd.nextDouble() * 0.82;
    final speed = 0.7 + rnd.nextDouble() * 1.6; // циклов в секунду
    final phase = rnd.nextDouble();
    return _AnimBar(env, speed, phase);
  });
}

double _animValue(_AnimBar b, double t) {
  final s = 0.55 + 0.45 * math.sin(2 * math.pi * (t * b.speed + b.phase));
  return (b.envelope * s).clamp(0.12, 1.0);
}

void _segmentedBar(Canvas c, double x, double width, double barTopY, double baseY, bool played) {
  if (!played) {
    c.drawRect(Rect.fromLTWH(x, barTopY, width, baseY - barTopY), Paint()..color = _dim);
    return;
  }
  final h = baseY - barTopY;
  final greyH = h * _segGreyFrac;
  final blueH = h * _segBlueFrac;
  c.drawRect(Rect.fromLTWH(x, baseY - greyH, width, greyH), Paint()..color = _segGrey);
  if (h > greyH) {
    final blueTop = math.max(barTopY, baseY - greyH - blueH);
    c.drawRect(Rect.fromLTWH(x, blueTop, width, (baseY - greyH) - blueTop), Paint()..color = _segBlue);
  }
  if (h > greyH + blueH) {
    c.drawRect(Rect.fromLTWH(x, barTopY, width, (baseY - greyH - blueH) - barTopY), Paint()..color = _segRed);
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter(this.bars, this.t, this.widthFrac);
  final List<_AnimBar> bars;
  final double t;
  final double widthFrac;
  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    final gap = size.width / n;
    final w = math.max(1.2, gap * widthFrac);
    for (var i = 0; i < n; i++) {
      final v = _animValue(bars[i], t);
      final h = (size.height * v).clamp(3.0, size.height);
      final x = i * gap + (gap - w) / 2;
      _segmentedBar(canvas, x, w, size.height - h, size.height, (i + 0.5) / n <= _p);
    }
  }

  @override
  bool shouldRepaint(covariant _EqPainter old) => true;
}

final _bars9 = _animBars(32, 3); // как №3 (оттенок по высоте) — 32 столбика
final _bars10 = _animBars(14, 4); // как №4 (крупные пухлые) — 14 столбиков
final _bars11 = _animBars(64, 5); // как №5 (спектроанализатор) — 64 столбика

class _Row {
  const _Row(this.no, this.title, this.bars, this.widthFrac);
  final String no;
  final String title;
  final List<_AnimBar> bars;
  final double widthFrac;
}

final _rows = [
  _Row('9', 'Оттенок по высоте — зонами', _bars9, 0.62),
  _Row('10', 'Крупные столбики — зонами', _bars10, 0.66),
  _Row('11', 'Спектроанализатор — зонами', _bars11, 0.5),
];

Widget _page(double t) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: Scaffold(
        backgroundColor: Afisha.bg,
        body: Align(
          alignment: Alignment.topCenter,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 16),
            for (final r in _rows)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: Afisha.lime, borderRadius: BorderRadius.circular(6)),
                      child: Text(r.no,
                          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                    Text(r.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                  ]),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 46,
                    child: Row(children: [
                      const SizedBox(width: 44, child: Text('1:12', style: _digitStyle, softWrap: false)),
                      const SizedBox(width: 12),
                      Expanded(child: CustomPaint(painter: _EqPainter(r.bars, t, r.widthFrac), size: Size.infinite)),
                      const SizedBox(width: 10),
                      const Text('4:33', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
                ]),
              ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );

void main() {
  setUpAll(() async {
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final f = File('assets/fonts/Inter-$w.ttf');
      if (f.existsSync()) {
        await (FontLoader('Inter')..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)))).load();
      }
    }
  });

  testWidgets('видео: анимация 9/10/11', (tester) async {
    const fps = 14;
    const seconds = 3.0;
    final frameCount = (fps * seconds).round();

    final key = GlobalKey();
    // Достаточно места под 3 ряда сразу — не меряем/не подгоняем, немного
    // чёрного снизу для видео не страшно.
    await tester.binding.setSurfaceSize(const Size(400, 420));
    await tester.pumpWidget(RepaintBoundary(key: key, child: _page(0)));
    await tester.pump();

    final dir = Directory('${Directory.current.path}/test/.tmp_eq_frames');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);

    final sampleTimes = [0.0, 1.0, 2.0, 2.9];
    final sampleFrames = <ui.Image>[];

    for (var i = 0; i < frameCount; i++) {
      final t = i / fps;
      await tester.pumpWidget(RepaintBoundary(key: key, child: _page(t)));
      await tester.pump();
      final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final img = await boundary.toImage(pixelRatio: 1);
        final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${dir.path}/frame_${i.toString().padLeft(3, '0')}.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        if (sampleTimes.any((st) => (st - t).abs() < (1 / fps) / 2)) {
          sampleFrames.add(img);
        }
      });
    }

    // Контрольный лист: 4 сэмпла друг под другом в одну картинку.
    if (sampleFrames.length >= 2) {
      final w0 = sampleFrames.first.width;
      final h0 = sampleFrames.first.height;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(Rect.fromLTWH(0, 0, w0.toDouble(), h0.toDouble() * sampleFrames.length),
            Paint()..color = const Color(0xFF000000));
        for (var k = 0; k < sampleFrames.length; k++) {
          canvas.drawImage(sampleFrames[k], Offset(0, h0.toDouble() * k), Paint());
        }
        final sheet = await recorder.endRecording().toImage(w0, h0 * sampleFrames.length);
        final bytes = (await sheet.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${dir.path}/../equalizer_animation_frames.png').writeAsBytes(bytes.buffer.asUint8List());
      });
    }

    expect(File('${dir.path}/frame_000.png').existsSync(), isTrue);
  });
}
