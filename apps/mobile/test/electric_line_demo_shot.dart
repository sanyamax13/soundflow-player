// Демо-набросок для Alex (TG 25.09.2026): стиль «электрическая» — дожат
// текстурой (плотный пучок из 7 дрожащих нитей + общая дымка), теперь
// цвет наслаивается по громкости (тот же приём, что и в кардиограмме и
// волне, вариант C): зелёный есть всегда, синий добавляется поверх от
// средней громкости, красный — поверх всего у самых громких мест.
// Наши брендовые lime/blue/red.
// НЕ финальный код, не подключён к player_view.
// Запуск: flutter test --update-goldens test/electric_line_demo_shot.dart
// Картинки: test/goldens/electric_c_frame_0..9.png

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _lime = Color(0xFFB2FF00);
const _blue = Color(0xFF4DA3FF);
const _red = Color(0xFFFF4D4D);

void main() {
  testWidgets('кадры: электрическая, наслоение цветов по громкости', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 160));
    final rnd = math.Random(5);
    final envelope = List<double>.generate(64, (_) => 0.18 + rnd.nextDouble() * 0.82);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(backgroundColor: Colors.black, body: Center(child: _Holder(envelope: envelope))),
    ));
    await tester.pump();

    final state = tester.state<_HolderState>(find.byType(_Holder));
    for (var frame = 0; frame < 10; frame++) {
      state.setProgress((frame + 0.5) / 10, frame);
      await tester.pump();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/electric_c_frame_$frame.png'));
    }
  });
}

class _Holder extends StatefulWidget {
  const _Holder({required this.envelope});
  final List<double> envelope;
  @override
  State<_Holder> createState() => _HolderState();
}

class _HolderState extends State<_Holder> {
  double _progress = 0.0;
  int _noiseFrame = 0;
  void setProgress(double v, int noiseFrame) => setState(() {
        _progress = v;
        _noiseFrame = noiseFrame;
      });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      height: 80,
      child: CustomPaint(
        painter: _ElectricPainter(envelope: widget.envelope, progress: _progress, noiseFrame: _noiseFrame),
      ),
    );
  }
}

class _ElectricPainter extends CustomPainter {
  _ElectricPainter({required this.envelope, required this.progress, required this.noiseFrame});
  final List<double> envelope;
  final double progress;
  final int noiseFrame;

  // Alex TG 25.09.2026: цвета НАСЛАИВАЮТСЯ по громкости в точке i (см.
  // pulse_line_demo_shot.dart / wave_line_demo_shot.dart, вариант C) —
  // альфа каждого цвета своя функция громкости, а не смена одного цвета.
  Shader _colorShader(Size size, Color color, double Function(double amp) alphaFn) {
    final n = envelope.length;
    final colors = [for (final v in envelope) color.withValues(alpha: alphaFn(v))];
    final stops = [for (var i = 0; i < n; i++) i / (n - 1)];
    return LinearGradient(colors: colors, stops: stops).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = envelope.length;
    final dx = size.width / (n - 1);
    final baseY = size.height / 2;
    final curX = progress * size.width;

    Path buildLayerPath(math.Random rnd, double jitterScale, {required bool played}) {
      final path = Path();
      Offset? prev;
      for (var i = 0; i < n; i++) {
        final x = i * dx;
        if (played ? x > curX : x <= curX) continue;
        final jitter = (rnd.nextDouble() - 0.5) * size.height * jitterScale * envelope[i];
        final y = baseY + jitter;
        if (prev == null) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        prev = Offset(x, y);
      }
      return path;
    }

    // общая мягкая дымка позади пучка — атмосфера/bloom, как на референсе;
    // зелёная и всегда ровная (базовый слой наслоения).
    final hazeRnd = math.Random(noiseFrame * 100 + 999);
    canvas.drawPath(buildLayerPath(hazeRnd, 0.55, played: true), Paint()
      ..shader = _colorShader(size, _lime, (amp) => 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16));

    const layerCount = 7;
    for (var layer = 0; layer < layerCount; layer++) {
      final rnd = math.Random(noiseFrame * 100 + layer * 7 + 3);
      final jitterScale = 0.3 + (layer % 3) * 0.12;
      final playedPath = buildLayerPath(rnd, jitterScale, played: true);
      final aheadPath = buildLayerPath(math.Random(noiseFrame * 100 + layer * 7 + 3), jitterScale, played: false);
      final core = layer < 2;
      final baseAlpha = core ? 0.85 : 0.3 + (layerCount - layer) * 0.05;

      // зелёный — узкий, есть всегда (не зависит от громкости в точке).
      canvas.drawPath(playedPath, Paint()
        ..shader = _colorShader(size, _lime, (amp) => baseAlpha * 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = core ? 1.2 : 0.7
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, core ? 1.6 : 3.0));
      // синий — пошире, добавляется от средней громкости.
      canvas.drawPath(playedPath, Paint()
        ..shader = _colorShader(size, _blue, (amp) => ((amp - 0.25) / 0.75).clamp(0.0, 1.0) * baseAlpha * 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = core ? 1.8 : 1.1
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, core ? 2.6 : 4.2));
      // красный — самый широкий + узкое яркое ядро поверх, только у громких мест.
      canvas.drawPath(playedPath, Paint()
        ..shader = _colorShader(size, _red, (amp) => ((amp - 0.6) / 0.4).clamp(0.0, 1.0) * baseAlpha * 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = core ? 2.6 : 1.6
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, core ? 3.6 : 5.4));
      canvas.drawPath(playedPath, Paint()
        ..shader = _colorShader(size, _red, (amp) => ((amp - 0.6) / 0.4).clamp(0.0, 1.0) * baseAlpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = core ? 0.7 : 0.4
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, core ? 0.8 : 1.2));

      if (core) {
        canvas.drawPath(playedPath, Paint()
          ..color = Colors.white.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..strokeJoin = StrokeJoin.round);
      }
      canvas.drawPath(aheadPath, Paint()
        ..color = Colors.white.withValues(alpha: baseAlpha * 0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..strokeJoin = StrokeJoin.round);
    }

    // ровная базовая линия под всем — на референсе тоже видна плоская
    // «нулевая» линия сквозь весь дёрганый узор.
    canvas.drawLine(Offset(0, baseY), Offset(size.width, baseY), Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 1);

    canvas.drawLine(Offset(curX, 0), Offset(curX, size.height), Paint()
      ..color = Colors.white.withValues(alpha: 0.4)
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _ElectricPainter old) => true;
}
