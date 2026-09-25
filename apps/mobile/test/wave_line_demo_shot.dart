// Демо-набросок для Alex (TG 25.09.2026): стиль «волна» — дожат текстурой
// (шум, многослойное свечение, белое ядро), теперь цвет наслаивается по
// громкости (Alex, голосовое: «зелёный есть всегда, синий добавляется
// поверх от средней громкости, красный — поверх всего у самых громких
// мест, все сочетаются» — тот же приём, что и в кардиограмме, вариант C).
// Наши брендовые lime/blue/red, не придуманные заново.
// НЕ финальный код, не подключён к player_view.
// Запуск: flutter test --update-goldens test/wave_line_demo_shot.dart
// Картинки: test/goldens/wave_c_frame_0..9.png

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _lime = Color(0xFFB2FF00);
const _blue = Color(0xFF4DA3FF);
const _red = Color(0xFFFF4D4D);

// только для искр — представительный цвет точки, не для основной линии
// (та красится наслоением, см. _colorShader в _WavePainter).
Color _loudnessColorSmooth(double amp) {
  if (amp < 0.5) return Color.lerp(_lime, _blue, amp / 0.5)!;
  return Color.lerp(_blue, _red, (amp - 0.5) / 0.5)!;
}

void main() {
  testWidgets('кадры: волна, наслоение цветов по громкости', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 160));
    final rnd = math.Random(5);
    final envelope = List<double>.generate(64, (_) => 0.18 + rnd.nextDouble() * 0.82);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(backgroundColor: Colors.black, body: Center(child: _Holder(envelope: envelope))),
    ));
    await tester.pump();

    final state = tester.state<_HolderState>(find.byType(_Holder));
    final rndSpark = math.Random(9);
    for (var frame = 0; frame < 10; frame++) {
      state.setProgress((frame + 0.5) / 10, rndSpark.nextDouble());
      await tester.pump();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/wave_c_frame_$frame.png'));
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
  double _sparkSeed = 0.0;
  void setProgress(double v, double sparkSeed) => setState(() {
        _progress = v;
        _sparkSeed = sparkSeed;
      });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      height: 80,
      child: CustomPaint(
        painter: _WavePainter(envelope: widget.envelope, progress: _progress, sparkSeed: _sparkSeed),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.envelope, required this.progress, required this.sparkSeed});
  final List<double> envelope;
  final double progress;
  final double sparkSeed;

  Offset _pointAt(int i, Size size) {
    final n = envelope.length;
    final dx = size.width / (n - 1);
    final jr = math.Random(i * 53 + (sparkSeed * 1000).toInt());
    final jitter = (jr.nextDouble() - 0.5) * size.height * 0.04;
    final y = size.height / 2 - (envelope[i] - 0.5) * size.height * 0.75 + jitter;
    return Offset(i * dx, y);
  }

  Path _smoothPath(Size size, double scale) {
    final n = envelope.length;
    final baseY = size.height / 2;
    final path = Path();
    for (var i = 0; i < n; i++) {
      final p = _pointAt(i, size);
      final scaled = Offset(p.dx, baseY + (p.dy - baseY) * scale);
      if (i == 0) {
        path.moveTo(scaled.dx, scaled.dy);
      } else {
        final prev = _pointAt(i - 1, size);
        final prevScaled = Offset(prev.dx, baseY + (prev.dy - baseY) * scale);
        final mid = Offset((prevScaled.dx + scaled.dx) / 2, (prevScaled.dy + scaled.dy) / 2);
        path.quadraticBezierTo(prevScaled.dx, prevScaled.dy, mid.dx, mid.dy);
      }
    }
    return path;
  }

  // Alex TG 25.09.2026 (голосовое): цвета НАСЛАИВАЮТСЯ, а не сменяют друг
  // друга — зелёный есть всегда, синий добавляется поверх от средней
  // громкости, красный — поверх всего, только у самых громких мест. Тот
  // же приём, что дожали в кардиограмме (см. pulse_line_demo_shot.dart,
  // вариант C) — тут применён к гладкой волне: три прохода по одной и той
  // же линии разными цветами/шириной, alpha каждого зависит от громкости
  // В ЭТОЙ ТОЧКЕ (через шейдер с alpha-стопами, не через смену Paint.color
  // построчно — так плавнее).
  Shader _colorShader(Size size, Color color, double Function(double amp) alphaFn) {
    final n = envelope.length;
    final colors = [for (final v in envelope) color.withValues(alpha: alphaFn(v))];
    final stops = [for (var i = 0; i < n; i++) i / (n - 1)];
    return LinearGradient(colors: colors, stops: stops).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = envelope.length;
    final playedCount = (progress * n).round();

    // слабые фоновые «хребты»-эхо (несколько уменьшенных копий волны) —
    // остаётся из референса, просто теперь бледно-лаймовые, не отдельный
    // цвет по позиции.
    final echoLayers = [(0.75, 8.0), (0.6, 5.0), (0.45, 3.0), (0.3, 2.0)];
    for (final (scale, blur) in echoLayers) {
      final path = _smoothPath(size, scale);
      canvas.drawPath(path, Paint()
        ..shader = _colorShader(size, _lime, (amp) => 0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur));
    }

    final mainPath = _smoothPath(size, 1.0);
    // зелёный — узкий контур, есть всегда
    canvas.drawPath(mainPath, Paint()
      ..shader = _colorShader(size, _lime, (amp) => 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    // синий — контур пошире, с средней громкости
    canvas.drawPath(mainPath, Paint()
      ..shader = _colorShader(size, _blue, (amp) => ((amp - 0.25) / 0.75).clamp(0.0, 1.0) * 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 11
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
    // красный — самый широкий, поверх всех, только у громких мест + ядро
    canvas.drawPath(mainPath, Paint()
      ..shader = _colorShader(size, _red, (amp) => ((amp - 0.6) / 0.4).clamp(0.0, 1.0) * 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    canvas.drawPath(mainPath, Paint()
      ..shader = _colorShader(size, _red, (amp) => ((amp - 0.6) / 0.4).clamp(0.0, 1.0) * 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1));
    canvas.drawPath(mainPath, Paint()
      ..color = Colors.white.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    if (playedCount < n) {
      final aheadPath = Path();
      for (var i = playedCount; i < n; i++) {
        final p = _pointAt(i, size);
        if (i == playedCount) {
          aheadPath.moveTo(p.dx, p.dy);
        } else {
          final prev = _pointAt(i - 1, size);
          final mid = Offset((prev.dx + p.dx) / 2, (prev.dy + p.dy) / 2);
          aheadPath.quadraticBezierTo(prev.dx, prev.dy, mid.dx, mid.dy);
        }
      }
      canvas.drawPath(aheadPath, Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 18);
      canvas.drawPath(aheadPath, Paint()
        ..color = Colors.white.withValues(alpha: 0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round);
    }

    final rnd = math.Random((sparkSeed * 1000).toInt());
    for (var i = 0; i < playedCount && i < n; i++) {
      if ((envelope[i] - 0.5).abs() < 0.35) continue;
      final p = _pointAt(i, size);
      final sparkColor = Color.lerp(_loudnessColorSmooth(envelope[i]), Colors.white, 0.5)!;
      final dx = (rnd.nextDouble() - 0.5) * 10;
      final dy = (rnd.nextDouble() - 0.5) * 10 - (envelope[i] > 0.5 ? 6 : -6);
      canvas.drawCircle(Offset(p.dx + dx, p.dy + dy), 1.1, Paint()..color = sparkColor.withValues(alpha: 0.6));
    }

    final curX = progress * size.width;
    canvas.drawLine(Offset(curX, 0), Offset(curX, size.height), Paint()
      ..color = Colors.white.withValues(alpha: 0.4)
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => true;
}
