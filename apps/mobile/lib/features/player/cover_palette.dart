import 'dart:async';
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
      var r = 0.0, g = 0.0, b = 0.0, count = 0.0;
      for (var i = 0; i + 3 < data.length; i += 4) {
        if (data[i + 3] < 128) continue;
        r += data[i];
        g += data[i + 1];
        b += data[i + 2];
        count++;
      }
      if (count == 0) return CoverColors.fallback;
      final avg = Color.fromARGB(
          255, (r / count).round(), (g / count).round(), (b / count).round());

      final h = HSLColor.fromColor(avg);
      final base = h
          .withSaturation((h.saturation * 0.9).clamp(0.22, 0.62))
          .withLightness(h.lightness.clamp(0.20, 0.40))
          .toColor();
      final glow = h
          .withHue((h.hue + 28) % 360)
          .withSaturation((h.saturation * 1.5).clamp(0.35, 0.8))
          .withLightness(0.5)
          .toColor();
      final deep = h
          .withHue((h.hue - 18) % 360)
          .withSaturation((h.saturation * 0.8).clamp(0.2, 0.6))
          .withLightness(0.12)
          .toColor();
      return CoverColors(base, glow, deep);
    } catch (_) {
      return CoverColors.fallback;
    }
  }
}
