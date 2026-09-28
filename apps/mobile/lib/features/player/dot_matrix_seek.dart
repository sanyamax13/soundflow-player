import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../core/theme.dart';
import 'glass_seek_painter.dart';
import 'player_controller.dart';
import 'seek_skin.dart';

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
/// Столбики впереди играющей точки стоят неподвижно (показывают тихую/громкую
/// форму трека без движения) — начинают «плясать», как только точка до них
/// доходит, и дальше уже не останавливаются (Alex TG 25.09.2026: «столбики
/// могут двигаться только когда доходит до них» — вариант «А» из двух
/// предложенных). Пляска — гладкое псевдослучайное колебание высоты, своя
/// скорость/фаза на столбик, фиксированный seed — настоящего звукового
/// анализа в реальном времени нет и не будет (принцип «сервер считает —
/// телефон сам», см. docs/SOUNDFLOW_OFFLINE_FIRST_PLAN.md), это имитация, как
/// в `equalizer_animation_shot.dart`. На паузе — замирают (в т.ч. уже
/// пляшущие).
/// Ничего не берёт с сервера: только позиция и длина трека, которые и так
/// есть у телефона.
class DotMatrixSeek extends StatefulWidget {
  const DotMatrixSeek({
    super.key,
    required this.controller,
    required this.tint,
    this.total = DotMatrixTotal.small,
    this.waveform,
    this.bass,
  });

  final PlayerController controller;

  /// Цвет крупных цифр «сколько прошло» (обычно цвет обложки) — сами
  /// столбики эквалайзера в фирменных лайм/синий/красный, независимо от
  /// обложки (Alex TG 23.09.2026: «лайм — это наш дефолтный цвет»).
  final Color tint;
  final DotMatrixTotal total;

  /// Настоящий рельеф громкости этой песни, 64 значения 0..1 — потолок
  /// пляски каждого столбика берётся отсюда, а не наугад (Alex TG
  /// 24.09.2026: «чтобы под музыку дрыгалась полоса, а не просто так»).
  /// null, пустой список или не 64 значения — столбики пляшут как раньше,
  /// случайно (сервер ещё не досчитал форму этой песни — см.
  /// apps/server/cmd/soundflow/wavekeeper.go).
  final ValueListenable<List<double>?>? waveform;

  /// Удары баса песни — 20 отметок 0..255 в секунду (те же, что для вспышки
  /// кнопки «играть»). По ним пляска живёт под песню (Alex TG 22544/22546,
  /// 27.09.2026): где удары частые — в драйвовом припеве, в быстром роке с
  /// первой секунды — столбики разгоняются; где редкие или их нет — медленный
  /// куплет, вступление — пляшут медленно. Смотрим именно частоту ударов, а
  /// не громкость относительно самой песни: у рока, драйвового от начала до
  /// конца, пляска быстрая всю песню. null — скорость как раньше, ровная.
  final ValueListenable<Uint8List?>? bass;

  // 46 → 64: зона захвата пальцем по высоте как у кнопок (разбор Gemini 26.09.2026).
  static const _height = 64.0;

  // Alex TG 25.09.2026 (по разбору Gemini): выразительный геометрический
  // шрифт для крупных цифр таймлайна вместо системного — даёт более
  // современный вид без структурных изменений.
  static const _digitStyle = TextStyle(
    fontFamily: 'SpaceGrotesk',
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  @override
  State<DotMatrixSeek> createState() => _DotMatrixSeekState();
}

class _DotMatrixSeekState extends State<DotMatrixSeek> with SingleTickerProviderStateMixin {
  static const _cols = 64;

  late final AnimationController _ticker;
  final Stopwatch _clock = Stopwatch();
  late final List<double> _speeds; // циклов пляски в секунду — свои, не меняются
  late final List<double> _phases;
  late List<double> _envelopes; // потолок пляски каждого столбика — меняется, когда придёт настоящая громкость

  // «Время пляски»: идёт быстрее или медленнее настоящего — по частоте ударов
  // в этом месте песни (см. [DotMatrixSeek.bass]). Скорость меняется плавно,
  // фаза столбиков не скачет.
  double _tau = 0;
  double _tempo = 1; // сглаженный множитель скорости
  int _lastUs = 0;
  List<double>? _tempoAt; // целевой множитель на каждую отметку баса (20 в секунду)
  double _pulse = 0; // удар баса сейчас, 0..1, гаснет за ~120 мс (вид «Стекло»)

  @override
  void initState() {
    super.initState();
    // Просто «метроном» перерисовки — само время берём из Stopwatch (его
    // можно ставить на паузу вместе с треком, не теряя фазу пляски).
    _ticker = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..addListener(_advance)
      ..repeat();
    final rnd = math.Random(5);
    _envelopes = List<double>.generate(_cols, (_) => 0.18 + rnd.nextDouble() * 0.82);
    _speeds = List<double>.generate(_cols, (_) => 0.7 + rnd.nextDouble() * 1.6); // циклов в секунду
    _phases = List<double>.generate(_cols, (_) => rnd.nextDouble());
    widget.controller.playing.addListener(_syncPlaying);
    widget.waveform?.addListener(_onWaveform);
    widget.bass?.addListener(_onBass);
    _onBass();
    seekSkin.addListener(_onSkin);
    _onWaveform();
    _syncPlaying();
  }

  // Пришла настоящая громкость этой песни (или сменился трек) — потолок
  // пляски каждого столбика берём из неё; скорость/фаза свои остаются, чтобы
  // столбики не застыли неподвижно, а продолжали живо дрожать вокруг
  // настоящей высоты. Не подошло по длине/нет данных — молча оставляем как
  // было (случайный потолок).
  void _onWaveform() {
    final wf = widget.waveform?.value;
    if (wf == null || wf.length != _cols) return;
    setState(() {
      _envelopes = [for (final v in wf) 0.15 + v.clamp(0.0, 1.0) * 0.85];
    });
  }

  void _onBass() {
    final b = widget.bass?.value;
    _tempoAt = (b == null || b.isEmpty) ? null : bassTempo(b);
  }

  void _onSkin() => setState(() {});

  // Кадр: сдвинуть «время пляски» на прошедшее время × текущую скорость.
  void _advance() {
    final us = _clock.elapsedMicroseconds;
    final dt = (us - _lastUs) / 1e6;
    _lastUs = us;
    if (dt <= 0) return; // пауза — стоим
    var target = 1.0;
    final tp = _tempoAt;
    final i = widget.controller.position.value.inMilliseconds ~/ 50;
    if (tp != null && i >= 0 && i < tp.length) target = tp[i];
    final b = widget.bass?.value;
    final hit = (b != null && i >= 0 && i < b.length) ? b[i] / 255 : 0.0;
    _pulse = math.max(hit, _pulse * math.exp(-dt / 0.12));
    // ~0.7 с на смену скорости: разгон к припеву и спад заметны, но без рывков
    _tempo += (target - _tempo) * (1 - math.exp(-dt / 0.7));
    _tau += dt * _tempo;
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
    widget.waveform?.removeListener(_onWaveform);
    widget.bass?.removeListener(_onBass);
    seekSkin.removeListener(_onSkin);
    _ticker.dispose();
    super.dispose();
  }

  bool _touching = false;
  int _lastTick = -1;
  double? _touchX; // где палец над полосой — для пузыря с временем
  bool _showRemaining = false; // «/ 3:37» ↔ «/ −2:51» — нажатием на время

  void _setTouching(bool v) {
    if (_touching != v) setState(() => _touching = v);
    if (!v) {
      _lastTick = -1;
      if (_touchX != null) setState(() => _touchX = null);
    }
  }

  void _seekAt(double dx, double width, int totalMs) {
    if (totalMs <= 0 || width <= 0) return;
    final frac = (dx / width).clamp(0.0, 1.0);
    // Лёгкий «щелчок» каждые 5% — перемотка ощущается как колёсико, можно
    // вести не глядя (разбор Gemini 26.09.2026).
    final tick = (frac * 20).floor();
    if (_lastTick != -1 && tick != _lastTick) HapticFeedback.selectionClick();
    _lastTick = tick;
    setState(() => _touchX = dx.clamp(0.0, width));
    widget.controller.seek(Duration(milliseconds: (totalMs * frac).round()));
  }

  // Вариант «5 + 4» разбора Gemini (Alex TG 21761, 26.09.2026):
  //  • время НАД полосой слева: крупно «0:46», рядом мелко «/ 3:37»; нажатие на время —
  //    «/ −2:51» (сколько осталось) и обратно; большая зона нажатия — в машине не промахнёшься;
  //  • полоса-эквалайзер — на всю ширину (раньше её сжимали цифры по бокам);
  //  • ведёшь пальцем по полосе — над пальцем стеклянный пузырь с временем, палец цифры не закрывает.
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.controller.duration,
      builder: (_, dur, _) => ValueListenableBuilder<Duration>(
        valueListenable: widget.controller.position,
        builder: (_, pos, _) {
          final totalMs = dur.inMilliseconds;
          final frac = totalMs <= 0 ? 0.0 : (pos.inMilliseconds / totalMs).clamp(0.0, 1.0);
          final left = dur - pos < Duration.zero ? Duration.zero : dur - pos;
          final side = widget.total == DotMatrixTotal.none
              ? null
              : (_showRemaining || widget.total == DotMatrixTotal.remaining)
                  ? '−${formatMmss(left)}'
                  : formatMmss(dur);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GestureDetector(
                  key: const ValueKey('dot_matrix_time'),
                  behavior: HitTestBehavior.opaque,
                  onTap: side == null
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          setState(() => _showRemaining = !_showRemaining);
                        },
                  child: SizedBox(
                    height: 40,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: formatMmss(pos),
                              style: DotMatrixSeek._digitStyle.copyWith(color: Colors.white),
                            ),
                            if (side != null)
                              TextSpan(
                                text: '  /  $side',
                                style: DotMatrixSeek._digitStyle.copyWith(
                                    fontSize: 16, color: Colors.white.withValues(alpha: 0.5)),
                              ),
                          ]),
                          maxLines: 1,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: DotMatrixSeek._height,
                  child: LayoutBuilder(
                    builder: (context, c) => Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            key: const ValueKey('dot_matrix_seek_area'),
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (d) {
                              _setTouching(true);
                              _seekAt(d.localPosition.dx, c.maxWidth, totalMs);
                            },
                            onTapUp: (_) => _setTouching(false),
                            onTapCancel: () => _setTouching(false),
                            onHorizontalDragStart: (_) => _setTouching(true),
                            onHorizontalDragUpdate: (d) => _seekAt(d.localPosition.dx, c.maxWidth, totalMs),
                            onHorizontalDragEnd: (_) => _setTouching(false),
                            onHorizontalDragCancel: () => _setTouching(false),
                            // Под пальцем полоса чуть подрастает — видно, что её «взяли».
                            child: AnimatedScale(
                              scale: _touching ? 1.15 : 1.0,
                              duration: const Duration(milliseconds: 140),
                              curve: Curves.easeOutQuad,
                              child: AnimatedBuilder(
                                animation: _ticker,
                                builder: (context, _) => CustomPaint(
                                  size: Size.infinite,
                                  painter: seekSkin.value == SeekSkin.glass
                                      ? GlassSeekPainter(progress: frac, t: _tau, pulse: _pulse)
                                      : _EqualizerPainter(
                                          envelopes: _envelopes,
                                          speeds: _speeds,
                                          phases: _phases,
                                          t: _tau,
                                          progress: frac,
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_touchX != null)
                          Positioned(
                            left: (_touchX! - 56).clamp(-8.0, c.maxWidth - 104),
                            top: -64,
                            child: IgnorePointer(child: _TimeBubble(text: formatMmss(pos))),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Стеклянный пузырь с временем над пальцем при перемотке (вариант 4 разбора Gemini).
class _TimeBubble extends StatelessWidget {
  const _TimeBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.7, end: 1),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutBack,
      builder: (_, s, child) => Transform.scale(scale: s, child: child),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            width: 112,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Text(text,
                style: DotMatrixSeek._digitStyle.copyWith(fontSize: 28, color: Afisha.lime)),
          ),
        ),
      ),
    );
  }
}

/// Множитель скорости пляски на каждую отметку баса (20 в секунду): считаем
/// удары (заметный всплеск, выше соседей, не чаще раза в 150 мс) в окне ±1.5 с,
/// каждый с весом своей силы (0..1), и переводим в скорость. Сила нужна, чтобы
/// после припева, где бочка продолжает стучать, но тише, пляска тоже спадала
/// (Alex TG 22554, 28.09.2026, Galantis «Runaway»: «почему не замедляется»).
/// Ударов нет (тихое вступление) — ×0.45, два сильных в секунду — ×1.45,
/// чаще — до ×2.
@visibleForTesting
List<double> bassTempo(Uint8List env) {
  const minHit = 90, minGap = 3, half = 30;
  final n = env.length;
  final hit = List<double>.filled(n + 1, 0); // накопленная сила ударов до i
  var last = -minGap;
  for (var i = 0; i < n; i++) {
    final v = env[i];
    final isHit = v >= minHit &&
        (i == 0 || v >= env[i - 1]) &&
        (i == n - 1 || v > env[i + 1]) &&
        i - last >= minGap;
    if (isHit) last = i;
    hit[i + 1] = hit[i] + (isHit ? v / 255 : 0);
  }
  return List<double>.generate(n, (i) {
    final a = math.max(0, i - half), b = math.min(n, i + half);
    final rate = (hit[b] - hit[a]) / ((b - a) / 20);
    return (0.45 + 0.5 * rate).clamp(0.45, 2.0);
  });
}

double _eqBarValue(double envelope, double speed, double phase, double t) {
  final s = 0.55 + 0.45 * math.sin(2 * math.pi * (t * speed + phase));
  return (envelope * s).clamp(0.12, 1.0);
}

// 25.09.2026 (Alex TG, голосовое): «когда достигает пика — красная плашечка
// остаётся вверху и постепенно чуть-чуть падает, потом снова подбивает
// наверх» — как пиковый индикатор на старом аппаратном VU-метре. Столбик
// каждый цикл поднимается ровно до envelope (математический максимум
// синуса в _eqBarValue), поэтому момент и высоту пика можно посчитать
// заранее по формуле, без отдельной память между кадрами: держим потолок
// сразу после пика, затем линейно роняем к текущей живой высоте столбика,
// пока не подоспеет следующий пик.
double _peakHoldValue(double envelope, double speed, double phase, double t, double liveV) {
  // 25.09.2026 (Alex TG, фото с живого телефона): «пусть не так быстро
  // прыгает, что бы было видно как падает» — было hold 0.05/fall 0.4, на
  // столбиках с коротким циклом (до 0.43с) плашка почти сразу подбивало
  // обратно наверх, падение толком не успевало показаться. Дольше держит
  // потолок и дольше падает.
  const hold = 0.12; // секунд держится на самом верху
  const fall = 0.9; // секунд падает оттуда до нуля
  final x = t * speed + phase;
  final k = (x - 0.25).floorToDouble();
  final tPeak = (0.25 + k - phase) / speed;
  final elapsed = t - tPeak;
  final decayed = elapsed <= hold ? envelope : envelope * (1 - ((elapsed - hold) / fall).clamp(0.0, 1.0));
  return math.max(decayed, liveV);
}

class _EqualizerPainter extends CustomPainter {
  const _EqualizerPainter({
    required this.envelopes,
    required this.speeds,
    required this.phases,
    required this.t,
    required this.progress,
  });

  final List<double> envelopes;
  final List<double> speeds;
  final List<double> phases;
  final double t;
  final double progress;

  static const _greyFrac = 0.55; // где по высоте столбика лайм переходит в синий
  static const _blue = Color(0xFF4DA3FF);
  static const _red = Color(0xFFFF4D4D);
  static final _dim = Colors.white.withValues(alpha: 0.16);

  // 25.09.2026 (Alex TG, «полосу прогресса оставь как есть, но дизайн чуть
  // переделай под iOS/Samsung»): скруглённые сверху и снизу «таблетки»
  // вместо острых углов.
  // 25.09.2026, разбор от трёх ИИ-дизайнеров по промту Alex (DeepSeek/
  // Gemini/GPT, независимо сошлись в одном): жёсткие цветные зоны (лайм/
  // синий/красный сплошными блоками со видимой границей) читаются как
  // «дешёвый VU-метр из 2005-го» — заменено на один плавный градиент по
  // высоте столбика (тот же лайм→синий→красный, но переход непрерывный,
  // без ступенек). Пропорции те же (_greyFrac), форма/пляска/пиковая
  // плашка не тронуты.
  void _segmentedBar(Canvas c, double x, double width, double barTopY, double baseY, bool played) {
    final r = Radius.circular(width / 2);
    final rect = Rect.fromLTWH(x, barTopY, width, baseY - barTopY);
    if (!played) {
      c.drawRRect(RRect.fromRectAndRadius(rect, r), Paint()..color = _dim);
      return;
    }
    final gradient = const LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [Afisha.lime, _blue, _red],
      stops: [0.0, _greyFrac, 1.0],
    );
    c.drawRRect(RRect.fromRectAndRadius(rect, r), Paint()..shader = gradient.createShader(rect));
  }

  // Пиковая «плашечка» — короткая красная чёрточка над самим столбиком,
  // висит на потолке цикла и сползает вниз (см. [_peakHoldValue]).
  void _peakCap(Canvas c, double x, double width, double capY) {
    const capH = 3.0;
    c.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x, capY - capH, width, capH), Radius.circular(width / 2)),
      Paint()..color = _red,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final n = envelopes.length;
    final gap = size.width / n;
    final w = math.max(1.2, gap * 0.5);
    for (var i = 0; i < n; i++) {
      final played = (i + 0.5) / n <= progress;
      // Впереди играющей точки — тихая неподвижная форма (сам envelope, без
      // пляски); плясать столбик начинает, только когда точка до него дошла.
      final v = played ? _eqBarValue(envelopes[i], speeds[i], phases[i], t) : envelopes[i].clamp(0.12, 1.0);
      final h = (size.height * v).clamp(3.0, size.height);
      final x = i * gap + (gap - w) / 2;
      _segmentedBar(canvas, x, w, size.height - h, size.height, played);
      if (played) {
        final peakV = _peakHoldValue(envelopes[i], speeds[i], phases[i], t, v);
        _peakCap(canvas, x, w, size.height - (size.height * peakV).clamp(3.0, size.height));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EqualizerPainter old) => true;
}
