import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Набор цветов из обложки, которыми плеер «переливается» на фоне (Alex TG
/// 18608: не обложка дышит, а фон медленно переливается под её цвет).
///  • [base] — приглушённый средний цвет;
///  • [glow] — тот же тон, но ярче и насыщеннее (блик перелива);
///  • [deep] — тёмный вариант для нижней части фона.
class CoverColors {
  const CoverColors(this.base, this.glow, this.deep);

  final Color base;
  final Color glow;
  final Color deep;

  static const fallback = CoverColors(
    Color(0xFF1A1A1A),
    Color(0xFF2A2A2A),
    Color(0xFF0C0C0C),
  );

  CoverColors lerpTo(CoverColors o, double t) => CoverColors(
        Color.lerp(base, o.base, t)!,
        Color.lerp(glow, o.glow, t)!,
        Color.lerp(deep, o.deep, t)!,
      );

  /// true — цвета обложки ещё не посчитаны (нет файла / ошибка): фон и точки перемотки
  /// показывают запасной серый, а не «переливаются» из ничего.
  bool get isFallback =>
      base == fallback.base &&
      glow == fallback.glow &&
      deep == fallback.deep;
}

/// Считаем цвета сами, без пакета: уменьшаем обложку до 16×16, усредняем
/// непрозрачные пиксели, из среднего тона выводим блик и тёмный. Кешируется
/// по [ImageProvider] в памяти процесса.
class CoverPalette {
  CoverPalette._();

  static final _cache = <Object, CoverColors>{};
  static final _inflight = <Object, Future<CoverColors>>{};

  static CoverColors? cached(ImageProvider? provider) =>
      provider == null ? null : _cache[provider];

  static Future<CoverColors> of(ImageProvider? provider) {
    if (provider == null) return Future.value(CoverColors.fallback);
    final hit = _cache[provider];
    if (hit != null) return Future.value(hit);
    return _inflight[provider] ??= _compute(provider).then((c) {
      _cache[provider] = c;
      _inflight.remove(provider);
      return c;
    });
  }

  static Future<CoverColors> _compute(ImageProvider provider) async {
    try {
      final stream = provider.resolve(ImageConfiguration.empty);
      final completer = Completer<ui.Image>();
      late ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      }, onError: (e, s) {
        if (!completer.isCompleted) completer.completeError(e);
        stream.removeListener(listener);
      });
      stream.addListener(listener);
      final image = await completer.future.timeout(const Duration(seconds: 6));

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final src = Rect.fromLTWH(
          0, 0, image.width.toDouble(), image.height.toDouble());
      canvas.drawImageRect(image, src, const Rect.fromLTWH(0, 0, 16, 16),
          ui.Paint()..filterQuality = FilterQuality.low);
      final small = await recorder.endRecording().toImage(16, 16);
      final bytes =
          await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      small.dispose();
      if (bytes == null) return CoverColors.fallback;

      final data = bytes.buffer.asUint8List();
      // Главный цвет — самый заметный ЯРКИЙ оттенок обложки, а не среднее всех точек (27.09.2026,
      // Alex: «задний фон коричневый, а на обложке его нет»). Среднее тёмно-синей обложки с лицами
      // давало грязно-бурый, а растяжка насыщенности и сдвиг оттенка делали из него коричневый.
      // Теперь: оттенки по 24 корзинам, вес точки — насыщенность × яркость, берём корзину с
      // наибольшим весом и средний цвет внутри неё. Обложка почти без цвета (ч/б, серая) — фон
      // тоже остаётся почти серым, цвет не выдумываем.
      const bins = 24;
      final wSum = List<double>.filled(bins, 0);
      final sSum = List<double>.filled(bins, 0);
      final vSum = List<double>.filled(bins, 0);
      final hx = List<double>.filled(bins, 0);
      final hy = List<double>.filled(bins, 0);
      var total = 0.0, px = 0.0, vAll = 0.0;
      for (var i = 0; i + 3 < data.length; i += 4) {
        if (data[i + 3] < 128) continue;
        final hsv = HSVColor.fromColor(Color.fromARGB(255, data[i], data[i + 1], data[i + 2]));
        px++;
        vAll += hsv.value;
        final w = hsv.saturation * hsv.value;
        if (w < 0.04) continue;
        final k = (hsv.hue / 360 * bins).floor() % bins;
        wSum[k] += w;
        sSum[k] += hsv.saturation * w;
        vSum[k] += hsv.value * w;
        hx[k] += math.cos(hsv.hue * math.pi / 180) * w;
        hy[k] += math.sin(hsv.hue * math.pi / 180) * w;
        total += w;
      }
      if (px == 0) return CoverColors.fallback;
      var best = 0;
      for (var k = 1; k < bins; k++) {
        if (wSum[k] > wSum[best]) best = k;
      }
      final vivid = total / px; // сколько в обложке цвета вообще (0 — ч/б)
      final hue = wSum[best] > 0 ? (math.atan2(hy[best], hx[best]) * 180 / math.pi + 360) % 360 : 0.0;
      final sat = wSum[best] > 0 ? sSum[best] / wSum[best] : 0.0;
      // Мало цвета — насыщенность фона пропорционально меньше (серая обложка → почти серый фон).
      final colorful = (vivid / 0.12).clamp(0.0, 1.0);
      final h = HSLColor.fromAHSL(1, hue, (sat * colorful).clamp(0.0, 1.0), (vAll / px).clamp(0.2, 0.5));
      final base = h
          .withSaturation((h.saturation * 0.9).clamp(0.04, 0.62))
          .withLightness(0.30)
          .toColor();
      final glow = h
          .withSaturation((h.saturation * 1.2).clamp(0.05, 0.8))
          .withLightness(0.5)
          .toColor();
      final deep = h
          .withHue((h.hue - 10) % 360)
          .withSaturation((h.saturation * 0.8).clamp(0.03, 0.6))
          .withLightness(0.12)
          .toColor();
      return CoverColors(base, glow, deep);
    } catch (_) {
      return CoverColors.fallback;
    }
  }
}
