// Демо-набросок для Alex (TG 25.09.2026): «а если в виде пульса это
// сделать?» — направление (кардиограмма) одобрено, дожато до текстуры
// («шум/слои свечения/белое ядро» по критике «пересказал по заголовку»).
// Дальше Alex (голосовое): «эти волны могут переходить... спокойная —
// салатовая, погромче — синяя, совсем громкая — красная... по каждому
// варианту забабахай по 2 примера». Цвета — НАШИ брендовые зоны из
// текущего эквалайзера (lime/blue/red, см. dot_matrix_seek.dart), не
// придуманные заново. Тут 2 варианта раскраски по громкости для стиля
// «кардиограмма»:
//  A — ПЛАВНО (цвет каждого удара — непрерывный переход лайм→синий→
//      красный по его громкости, соседние удары перетекают друг в друга)
//  B — ЗОНАМИ (жёсткая граница — тихо=лайм, средне=синий, громко=красный,
//      как отдельные «светофорные» сегменты, без перетекания)
// НЕ финальный код, не подключён к player_view.
// Запуск: flutter test --update-goldens test/pulse_line_demo_shot.dart
// Картинки: test/goldens/pulse_a_frame_0..9.png, pulse_b_frame_0..9.png

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _lime = Color(0xFFB2FF00);
const _blue = Color(0xFF4DA3FF);
const _red = Color(0xFFFF4D4D);

// непрерывный переход лайм→синий→красный по громкости 0..1
Color _loudnessColorSmooth(double amp) {
  if (amp < 0.5) return Color.lerp(_lime, _blue, amp / 0.5)!;
  return Color.lerp(_blue, _red, (amp - 0.5) / 0.5)!;
}

// жёсткие зоны — как в проде (_greyFrac=0.55, _blueFrac=0.35 в dot_matrix_seek.dart)
Color _loudnessColorZoned(double amp) {
  if (amp < 0.55) return _lime;
  if (amp < 0.90) return _blue;
  return _red;
}

void main() {
  testWidgets('кадры A: кардиограмма, плавный цвет по громкости', (tester) async {
    await _runDemo(tester, goldenPrefix: 'pulse_a_frame', colorFn: _loudnessColorSmooth);
  });

  testWidgets('кадры B: кардиограмма, цвет зонами по громкости', (tester) async {
    await _runDemo(tester, goldenPrefix: 'pulse_b_frame', colorFn: _loudnessColorZoned);
  });

  // Alex TG 25.09.2026 (голосовое, подтвердил «так»): цвета не должны резко
  // СМЕНЯТЬ друг друга — они НАСЛАИВАЮТСЯ: даже в самом громком месте
  // должны проглядывать зелёный/синий по краям. A и B красят линию в ОДИН
  // цвет по громкости — это была неправильная трактовка. C рисует все три
  // цвета друг НАД другом (зелёный всегда есть, синий добавляется поверх
  // от среднего, красное ядро поверх всего только у самых громких мест).
  testWidgets('кадры C: кардиограмма, наслоение цветов', (tester) async {
    await _runDemo(tester, goldenPrefix: 'pulse_c_frame', colorFn: _loudnessColorSmooth, layered: true);
  });
}

Future<void> _runDemo(
  WidgetTester tester, {
  required String goldenPrefix,
  required Color Function(double amp) colorFn,
  bool layered = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(400, 160));
  final rnd = math.Random(5);
  final raw = List<double>.generate(64, (_) => 0.18 + rnd.nextDouble() * 0.82);
  final beats = <double>[for (var i = 0; i < 64; i += 4) raw.sublist(i, i + 4).reduce(math.max)];
  final rndSpacing = math.Random(11);
  final widths = List<double>.generate(beats.length, (_) => 0.7 + rndSpacing.nextDouble() * 0.6);

  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: _Holder(beats: beats, widths: widths, colorFn: colorFn, layered: layered)),
    ),
  ));
  await tester.pump();

  final state = tester.state<_HolderState>(find.byType(_Holder));
  final rndSpark = math.Random(9);
  for (var frame = 0; frame < 10; frame++) {
    state.setProgress((frame + 0.5) / 10, rndSpark.nextDouble());
    await tester.pump();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${goldenPrefix}_$frame.png'));
  }
}

class _Holder extends StatefulWidget {
  const _Holder({required this.beats, required this.widths, required this.colorFn, this.layered = false});
  final List<double> beats;
  final List<double> widths;
  final Color Function(double amp) colorFn;
  final bool layered;
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
        painter: _EcgPainter(
          beats: widget.beats,
          widths: widget.widths,
          progress: _progress,
          sparkSeed: _sparkSeed,
          colorFn: widget.colorFn,
          layered: widget.layered,
        ),
      ),
    );
  }
}

class _EcgPainter extends CustomPainter {
  _EcgPainter({
    required this.beats,
    required this.widths,
    required this.progress,
    required this.sparkSeed,
    required this.colorFn,
    this.layered = false,
  });
  final List<double> beats;
  final List<double> widths;
  final double progress;
  final double sparkSeed;
  final Color Function(double amp) colorFn;
  final bool layered;

  @override
  void paint(Canvas canvas, Size size) {
    final n = beats.length;
    final widthSum = widths.reduce((a, b) => a + b);
    final scale = size.width / widthSum;
    final segWs = [for (final w in widths) w * scale];
    final xs = <double>[0];
    for (final w in segWs) {
      xs.add(xs.last + w);
    }
    final baseY = size.height / 2;

    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 12) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 0.0; y < size.height; y += 12) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    Path beatPath(double x0, double w, double amp, int seed) {
      final h = size.height * 0.38 * amp;
      final jr = math.Random(seed);
      double j() => (jr.nextDouble() - 0.5) * size.height * 0.05;
      final rWobble = 0.9 + jr.nextDouble() * 0.2;
      final p = Path()..moveTo(x0, baseY + j());
      for (var f = 0.02; f <= 0.13; f += 0.028) {
        p.lineTo(x0 + w * f, baseY + j());
      }
      p.quadraticBezierTo(x0 + w * 0.18, baseY - h * 0.15, x0 + w * 0.22, baseY + j());
      for (var f = 0.25; f <= 0.34; f += 0.03) {
        p.lineTo(x0 + w * f, baseY + j());
      }
      p.lineTo(x0 + w * 0.40, baseY - h * 0.25 * rWobble);
      p.lineTo(x0 + w * 0.44, baseY - h * rWobble);
      p.lineTo(x0 + w * 0.50, baseY + h * 0.85 * rWobble);
      p.lineTo(x0 + w * 0.56, baseY + j());
      for (var f = 0.58; f <= 0.80; f += 0.03) {
        p.lineTo(x0 + w * f, baseY + j());
      }
      p.quadraticBezierTo(x0 + w * 0.72, baseY - h * 0.22, x0 + w * 0.82, baseY + j());
      for (var f = 0.85; f <= 1.0; f += 0.03) {
        p.lineTo(x0 + w * f, baseY + j());
      }
      return p;
    }

    final curXForSplit = progress * size.width;
    var playedBeats = 0;
    for (var i = 0; i < n; i++) {
      if (xs[i] < curXForSplit) playedBeats = i + 1;
    }

    void drawGlow(Path path, Color color, bool played, double boost) {
      if (played) {
        canvas.drawPath(path, Paint()
          ..color = color.withValues(alpha: 0.22 * boost)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 16 * boost
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14));
      }
      canvas.drawPath(path, Paint()
        ..color = (played ? color : Colors.white.withValues(alpha: 0.22)).withValues(alpha: played ? 0.5 * boost : 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7 * boost
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      canvas.drawPath(path, Paint()
        ..color = played ? color : Colors.white.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6 * boost
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2));
      canvas.drawPath(path, Paint()
        ..color = played ? Colors.white.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..strokeJoin = StrokeJoin.round);
    }

    // Alex TG 25.09.2026 (голосовое, второй заход): «на каждом импульсе
    // три — зелёный чуть поменьше, синий чуть побольше контур, красный
    // [самый большой]... слабый звук — только зелёное, среднее — зелёное
    // и синее вместе, сильное — красное полностью, но и синий с зелёным
    // тоже, все сочетаются». Не один контур с alpha по громкости (как
    // было), а РАСТУЩИЕ концентрические контуры — зелёный маленький и
    // всегда есть, синий шире и добавляется со средней громкости, красный
    // — самый широкий, поверх всех, только у самых громких мест. Цвета
    // естественно смешиваются в местах наложения (зелёный+синий на
    // экране даёт бирюзовый/голубо-зелёный, не жёлтый — жёлтый получается
    // при смешении красок, не света; тут светящиеся слои, как в неоне).
    void drawGlowLayered(Path path, double amp, bool played, double boost) {
      if (!played) {
        canvas.drawPath(path, Paint()
          ..color = Colors.white.withValues(alpha: 0.22)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeJoin = StrokeJoin.round);
        return;
      }
      // зелёный — маленький контур, есть всегда
      canvas.drawPath(path, Paint()
        ..color = _lime.withValues(alpha: 0.55 * boost)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (4 + amp * 3) * boost
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + amp * 2));
      // синий — контур пошире, добавляется со средней громкости
      final blueT = ((amp - 0.25) / 0.75).clamp(0.0, 1.0);
      if (blueT > 0) {
        canvas.drawPath(path, Paint()
          ..color = _blue.withValues(alpha: blueT * 0.5 * boost)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (9 + amp * 6) * boost
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + amp * 4));
      }
      // красный — самый широкий контур, поверх всех, только у громких мест
      final redT = ((amp - 0.6) / 0.4).clamp(0.0, 1.0);
      if (redT > 0) {
        canvas.drawPath(path, Paint()
          ..color = _red.withValues(alpha: redT * 0.6 * boost)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (15 + amp * 8) * boost
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 + amp * 4));
        // яркое красное ядро поверх широкого контура — иначе на громких
        // местах красный тонет в собственном широком размытии
        canvas.drawPath(path, Paint()
          ..color = _red.withValues(alpha: redT * 0.9 * boost)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4 * boost
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1));
      }
      canvas.drawPath(path, Paint()
        ..color = Colors.white.withValues(alpha: 0.55 + amp * 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..strokeJoin = StrokeJoin.round);
    }

    for (var i = 0; i < n; i++) {
      final path = beatPath(xs[i], segWs[i], beats[i], i * 97 + (sparkSeed * 1000).toInt());
      final played = i < playedBeats;
      final boost = played && i == playedBeats - 1 ? 1.4 : 1.0;
      if (layered) {
        drawGlowLayered(path, beats[i], played, boost);
      } else {
        drawGlow(path, colorFn(beats[i]), played, boost);
      }
    }

    final rnd = math.Random((sparkSeed * 1000).toInt());
    for (var i = 0; i < playedBeats && i < n; i++) {
      if (beats[i] < 0.75) continue;
      final peakX = xs[i] + segWs[i] * 0.44;
      final peakY = baseY - size.height * 0.38 * beats[i];
      final sparkColor = colorFn(beats[i]);
      for (var s = 0; s < 2; s++) {
        final dx = (rnd.nextDouble() - 0.5) * 14;
        final dy = -rnd.nextDouble() * 16 - 4;
        canvas.drawCircle(
          Offset(peakX + dx, peakY + dy),
          1.2,
          Paint()..color = Color.lerp(sparkColor, Colors.white, 0.5)!.withValues(alpha: 0.5 + rnd.nextDouble() * 0.4),
        );
      }
    }

    final curX = progress * size.width;
    canvas.drawLine(Offset(curX, 0), Offset(curX, size.height), Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _EcgPainter old) => true;
}
