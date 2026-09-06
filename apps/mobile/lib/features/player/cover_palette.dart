import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../core/theme.dart';

/// Цвет, в который плеер «одевается» под обложку (Alex TG 18571/18578 +
/// разбор дизайнера: экран мягко берёт цвет альбома, лайм остаётся только у
/// главной кнопки). Считаем сами, без пакета: уменьшаем картинку до 16×16,
/// усредняем непрозрачные пиксели, приглушаем яркость и держим умеренную
/// насыщенность — чтобы фон был «живым», а не кислотным.
///
/// Результат кешируется по [ImageProvider] в памяти процесса. Обложки нет /
/// не декодировалась — отдаём тёмный нейтральный [Afisha.surfaceHi].
class CoverPalette {
  CoverPalette._();

  static final _cache = <Object, Color>{};
  static final _inflight = <Object, Future<Color>>{};

  static Color? cached(ImageProvider? provider) =>
      provider == null ? null : _cache[provider];

  static Future<Color> of(ImageProvider? provider) {
    if (provider == null) return Future.value(Afisha.surfaceHi);
    final hit = _cache[provider];
    if (hit != null) return Future.value(hit);
    return _inflight[provider] ??= _compute(provider).then((c) {
      _cache[provider] = c;
      _inflight.remove(provider);
      return c;
    });
  }

  static Future<Color> _compute(ImageProvider provider) async {
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

      // Уменьшаем до 16×16 через рисование на маленький канвас.
      const n = 16;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final src = Rect.fromLTWH(
          0, 0, image.width.toDouble(), image.height.toDouble());
      canvas.drawImageRect(
          image, src, const Rect.fromLTWH(0, 0, 16, 16),
          ui.Paint()..filterQuality = FilterQuality.low);
      final small = await recorder.endRecording().toImage(n, n);
      final bytes =
          await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      small.dispose();
      if (bytes == null) return Afisha.surfaceHi;

      final data = bytes.buffer.asUint8List();
      var r = 0.0, g = 0.0, b = 0.0, count = 0.0;
      for (var i = 0; i + 3 < data.length; i += 4) {
        final a = data[i + 3];
        if (a < 128) continue;
        r += data[i];
        g += data[i + 1];
        b += data[i + 2];
        count++;
      }
      if (count == 0) return Afisha.surfaceHi;
      final avg = Color.fromARGB(
          255, (r / count).round(), (g / count).round(), (b / count).round());

      final hsl = HSLColor.fromColor(avg);
      return hsl
          .withSaturation((hsl.saturation * 0.9).clamp(0.25, 0.7))
          .withLightness(hsl.lightness.clamp(0.22, 0.42))
          .toColor();
    } catch (_) {
      return Afisha.surfaceHi;
    }
  }
}
