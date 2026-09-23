// 5 вариантов полосы перемотки в виде «прыгающего эквалайзера» (как в
// старом Winamp) вместо текущей точечной матрицы (dot_matrix_seek.dart).
// Картинки из НАСТОЯЩЕЙ отрисовки Flutter (тот же шрифт/цвета/цифры, что и
// у DotMatrixSeek), не из головы. Только эскиз вида — реальной перемотки
// тут нет (см. player_view.dart для настоящего интерактива). Не проверка
// логики, не трогает dot_matrix_seek.dart/player_view.dart.
// Запуск:
//   flutter test --update-goldens test/equalizer_variants_shot.dart
// Картинка: test/goldens/equalizer_variants_1.png
//
// Alex TG 23.09.2026 (через пересланный разговор с прежней сессией): «полоску
// сделать похожей на прыгающий эквалайзер, как в старом Winamp — но чтобы
// она всё равно работала как полоса перемотки»; «дай по 5 вариантов».

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/theme.dart';

const _p = 72 / 273; // 1:12 из 4:33 — та же позиция, что и на остальных картинках плеера.

Color get _lime => Afisha.lime;
Color get _dim => Colors.white.withValues(alpha: 0.16);

/// Столбики эквалайзера «прыгают» по бару независимо друг от друга (не
/// плавная волна громкости) — так выглядит настоящий Winamp-эквалайзер.
/// Фиксированный seed — картинка не меняется между запусками.
List<double> _bars(int n, int seed) {
  final rnd = math.Random(seed);
  return List<double>.generate(n, (_) => 0.18 + rnd.nextDouble() * 0.82);
}

const _digitStyle = TextStyle(
  fontSize: 24,
  fontWeight: FontWeight.w600,
  height: 1,
  fontFeatures: [FontFeature.tabularFigures()],
);

class _P extends CustomPainter {
  _P(this.f);
  final void Function(Canvas, Size) f;
  @override
  void paint(Canvas canvas, Size size) => f(canvas, size);
  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

Widget _paint(void Function(Canvas, Size) f) => CustomPaint(painter: _P(f), size: Size.infinite);

Paint _cap(Color c) => Paint()
  ..color = c
  ..strokeCap = StrokeCap.round;

// ── 1. Классика Winamp: частые узкие столбики от низа ──────────────────────
final _bars1 = _bars(40, 1);
void _classic(Canvas c, Size s) {
  final n = _bars1.length;
  final gap = s.width / n;
  for (var i = 0; i < n; i++) {
    final h = (s.height * _bars1[i]).clamp(3.0, s.height);
    final x = i * gap + gap / 2;
    c.drawLine(Offset(x, s.height), Offset(x, s.height - h),
        _cap((i + 0.5) / n <= _p ? _lime : _dim)..strokeWidth = gap * 0.6);
  }
}

// ── 2. Зеркальные столбики вверх/вниз от центра ─────────────────────────────
final _bars2 = _bars(36, 2);
void _mirror(Canvas c, Size s) {
  final n = _bars2.length;
  final gap = s.width / n;
  final mid = s.height / 2;
  for (var i = 0; i < n; i++) {
    final h = (mid * _bars2[i]).clamp(2.0, mid);
    final x = i * gap + gap / 2;
    c.drawLine(Offset(x, mid - h), Offset(x, mid + h),
        _cap((i + 0.5) / n <= _p ? _lime : _dim)..strokeWidth = gap * 0.58);
  }
}

// ── 3. Оттенок по высоте: выше столбик — ярче цвет (только в играной части) ─
final _bars3 = _bars(32, 3);
void _shaded(Canvas c, Size s) {
  final n = _bars3.length;
  final gap = s.width / n;
  for (var i = 0; i < n; i++) {
    final v = _bars3[i];
    final h = (s.height * v).clamp(3.0, s.height);
    final x = i * gap + gap / 2;
    final played = (i + 0.5) / n <= _p;
    final col = played ? Color.lerp(_lime.withValues(alpha: 0.45), _lime, v)! : _dim;
    c.drawLine(Offset(x, s.height), Offset(x, s.height - h), _cap(col)..strokeWidth = gap * 0.62);
  }
}

// ── 4. Крупные «пухлые» столбики, минималистичнее ───────────────────────────
final _bars4 = _bars(14, 4);
void _chunky(Canvas c, Size s) {
  final n = _bars4.length;
  final gap = s.width / n;
  for (var i = 0; i < n; i++) {
    final h = (s.height * _bars4[i]).clamp(6.0, s.height);
    final x = i * gap + gap / 2;
    c.drawLine(Offset(x, s.height), Offset(x, s.height - h),
        _cap((i + 0.5) / n <= _p ? _lime : _dim)..strokeWidth = gap * 0.66);
  }
}

// ── 5. Плотный спектроанализатор: много тонких столбиков ────────────────────
final _bars5 = _bars(64, 5);
void _spectrum(Canvas c, Size s) {
  final n = _bars5.length;
  final gap = s.width / n;
  for (var i = 0; i < n; i++) {
    final h = (s.height * _bars5[i]).clamp(2.0, s.height);
    final x = i * gap + gap / 2;
    c.drawLine(Offset(x, s.height), Offset(x, s.height - h),
        _cap((i + 0.5) / n <= _p ? _lime : _dim)..strokeWidth = math.max(1.2, gap * 0.5));
  }
}

/// Цвет по громкости столбика — классический VU-метр: тихо — серый,
/// средне — синий, громко (высокий столбик) — красный. Alex TG 23.09.2026
/// (голосовое): «книзу серый... к верху... самая громкая — красная, а
/// промежуточная где-то синий, как классический эквалайзер в Винампе».
Color _vuColor(double v) {
  const grey = Color(0xFF7A7A85);
  const blue = Color(0xFF4DA3FF);
  const red = Color(0xFFFF4D4D);
  return v < 0.5 ? Color.lerp(grey, blue, v / 0.5)! : Color.lerp(blue, red, (v - 0.5) / 0.5)!;
}

// ── 6 (цветной вариант 3): оттенок по высоте, но серый→синий→красный ───────
void _shadedVu(Canvas c, Size s) {
  final n = _bars3.length;
  final gap = s.width / n;
  for (var i = 0; i < n; i++) {
    final v = _bars3[i];
    final h = (s.height * v).clamp(3.0, s.height);
    final x = i * gap + gap / 2;
    final col = (i + 0.5) / n <= _p ? _vuColor(v) : _dim;
    c.drawLine(Offset(x, s.height), Offset(x, s.height - h), _cap(col)..strokeWidth = gap * 0.62);
  }
}

// ── 7 (цветной вариант 4): крупные пухлые столбики, VU-метром ──────────────
void _chunkyVu(Canvas c, Size s) {
  final n = _bars4.length;
  final gap = s.width / n;
  for (var i = 0; i < n; i++) {
    final v = _bars4[i];
    final h = (s.height * v).clamp(6.0, s.height);
    final x = i * gap + gap / 2;
    final col = (i + 0.5) / n <= _p ? _vuColor(v) : _dim;
    c.drawLine(Offset(x, s.height), Offset(x, s.height - h), _cap(col)..strokeWidth = gap * 0.66);
  }
}

// ── 8 (цветной вариант 5): плотный спектроанализатор, VU-метром ────────────
void _spectrumVu(Canvas c, Size s) {
  final n = _bars5.length;
  final gap = s.width / n;
  for (var i = 0; i < n; i++) {
    final v = _bars5[i];
    final h = (s.height * v).clamp(2.0, s.height);
    final x = i * gap + gap / 2;
    final col = (i + 0.5) / n <= _p ? _vuColor(v) : _dim;
    c.drawLine(Offset(x, s.height), Offset(x, s.height - h), _cap(col)..strokeWidth = math.max(1.2, gap * 0.5));
  }
}

// ── 9/10/11: не столбик целиком одним цветом, а КАЖДЫЙ столбик сам разбит
// на 3 зоны по высоте (серый низ → синий середина → красный верх), как
// на старом аппаратном эквалайзере/VU-метре — красная зона видна только у
// самых высоких столбиков. Alex TG 23.09.2026 (голосовое): «столбик сам
// определял, где тихо, где средне, где громко — и делился по цвету».
const _segGrey = Color(0xFF7A7A85);
const _segBlue = Color(0xFF4DA3FF);
const _segRed = Color(0xFFFF4D4D);
// Доли ВЫСОТЫ САМОГО СТОЛБИКА, не всей полосы — серая зона самая широкая,
// красная — только на самом верху, как на реальных индикаторах.
const _segGreyFrac = 0.55;
const _segBlueFrac = 0.35;
// Остаток (0.10) — красная зона.

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

void _shadedSeg(Canvas c, Size s) {
  final n = _bars3.length;
  final gap = s.width / n;
  final w = gap * 0.62;
  for (var i = 0; i < n; i++) {
    final h = (s.height * _bars3[i]).clamp(3.0, s.height);
    final x = i * gap + (gap - w) / 2;
    _segmentedBar(c, x, w, s.height - h, s.height, (i + 0.5) / n <= _p);
  }
}

void _chunkySeg(Canvas c, Size s) {
  final n = _bars4.length;
  final gap = s.width / n;
  final w = gap * 0.66;
  for (var i = 0; i < n; i++) {
    final h = (s.height * _bars4[i]).clamp(6.0, s.height);
    final x = i * gap + (gap - w) / 2;
    _segmentedBar(c, x, w, s.height - h, s.height, (i + 0.5) / n <= _p);
  }
}

void _spectrumSeg(Canvas c, Size s) {
  final n = _bars5.length;
  final gap = s.width / n;
  final w = math.max(1.2, gap * 0.5);
  for (var i = 0; i < n; i++) {
    final h = (s.height * _bars5[i]).clamp(2.0, s.height);
    final x = i * gap + (gap - w) / 2;
    _segmentedBar(c, x, w, s.height - h, s.height, (i + 0.5) / n <= _p);
  }
}

class _V {
  const _V(this.no, this.title, this.note, this.strip);
  final String no;
  final String title;
  final String note;
  final Widget Function() strip;
}

final _variants = <_V>[
  _V('1', 'Классика Winamp', 'частые узкие столбики от низа — самый узнаваемый вид', () => _paint(_classic)),
  _V('2', 'Зеркальные столбики', 'растут вверх и вниз от центральной линии, как VU-метр', () => _paint(_mirror)),
  _V('3', 'Оттенок по высоте', 'выше столбик — ярче цвет; в духе Winamp, но приглушённее', () => _paint(_shaded)),
  _V('4', 'Крупные «пухлые» столбики', 'немного широких столбиков — спокойнее, ближе к Apple', () => _paint(_chunky)),
  _V('5', 'Спектроанализатор', 'много тонких плотных столбиков — самый «настоящий Winamp»', () => _paint(_spectrum)),
  _V('6', 'Оттенок по высоте — VU-метр (как №3, цветной)',
      'та же форма столбиков, что и в №3, но цвет по громкости: серый→синий→красный', () => _paint(_shadedVu)),
  _V('7', 'Крупные столбики — VU-метр (как №4, цветной)',
      'та же форма столбиков, что и в №4, но цвет по громкости: серый→синий→красный', () => _paint(_chunkyVu)),
  _V('8', 'Спектроанализатор — VU-метр (как №5, цветной)',
      'та же форма столбиков, что и в №5, но цвет по громкости: серый→синий→красный', () => _paint(_spectrumVu)),
  _V('9', 'Оттенок по высоте — зонами (как №3)',
      'каждый столбик сам разбит на 3 зоны по высоте: серый→синий→красный, а не целиком одним цветом',
      () => _paint(_shadedSeg)),
  _V('10', 'Крупные столбики — зонами (как №4)',
      'каждый столбик сам разбит на 3 зоны по высоте: серый→синий→красный, а не целиком одним цветом',
      () => _paint(_chunkySeg)),
  _V('11', 'Спектроанализатор — зонами (как №5)',
      'каждый столбик сам разбит на 3 зоны по высоте: серый→синий→красный, а не целиком одним цветом',
      () => _paint(_spectrumSeg)),
];

Widget _row(_V v) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: _lime, borderRadius: BorderRadius.circular(6)),
            child: Text(v.no,
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 12)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(v.title,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
          ),
        ]),
        const SizedBox(height: 3),
        Text(v.note, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        const SizedBox(height: 10),
        // Тот же ряд, что и в DotMatrixSeek: крупные цифры «прошло» слева,
        // полоса по центру, маленькая общая длина справа.
        SizedBox(
          height: 46,
          child: Row(children: [
            const SizedBox(
              width: 44,
              child: Text('1:12', style: _digitStyle, softWrap: false, overflow: TextOverflow.visible),
            ),
            const SizedBox(width: 12),
            Expanded(child: v.strip()),
            const SizedBox(width: 10),
            const Text('4:33', style: TextStyle(color: Colors.white38, fontSize: 12)),
          ]),
        ),
        const SizedBox(height: 10),
        Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
      ]),
    );

Widget _page(Key key) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: Scaffold(
        backgroundColor: Afisha.bg,
        body: Align(
          alignment: Alignment.topCenter,
          child: Column(key: key, mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 8),
            for (final v in _variants) _row(v),
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
        await (FontLoader('Inter')..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)))).load();
      }
    }
  });

  testWidgets('варианты эквалайзер-полосы', (t) async {
    final key = GlobalKey();
    await t.binding.setSurfaceSize(const Size(400, 1600));
    await t.pumpWidget(_page(key));
    await t.pump();
    final h = t.getSize(find.byKey(key)).height + 16;
    await t.binding.setSurfaceSize(Size(400, h));
    await t.pumpWidget(_page(GlobalKey()));
    await t.pump();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/equalizer_variants_1.png'));
  });
}
