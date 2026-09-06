import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/theme.dart';

/// Провайдер картинки обложки: локальный файл у скачанных, иначе адрес на
/// сервере. null — обложки нет нигде.
ImageProvider? coverImageProvider(String trackId, String? localPath) {
  final p = localPath;
  if (p != null && p.isNotEmpty && File(p).existsSync()) {
    return FileImage(File(p));
  }
  final url = coverUrlFor(trackId);
  return url.isEmpty ? null : NetworkImage(url);
}

/// Средний цвет картинки — для заливки фона плеера под цвет обложки
/// (Alex 06.09.2026). Считаем по прореженной выборке пикселей, без внешних
/// пакетов. Не вышло — null, фон остаётся просто размытой обложкой.
Future<Color?> averageColorOf(ImageProvider provider) async {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(const ImageConfiguration());
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!completer.isCompleted) completer.complete(info.image);
      stream.removeListener(listener);
    },
    onError: (e, _) {
      if (!completer.isCompleted) completer.completeError(e);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);

  final ui.Image image;
  try {
    image = await completer.future;
  } catch (_) {
    return null;
  }
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return null;
  final bytes = data.buffer.asUint8List();
  final pixels = bytes.length ~/ 4;
  if (pixels == 0) return null;
  final step = ((pixels / 2500).ceil()).clamp(1, 4096) * 4;
  var r = 0, g = 0, b = 0, n = 0;
  for (var i = 0; i + 3 < bytes.length; i += step) {
    if (bytes[i + 3] < 128) continue;
    r += bytes[i];
    g += bytes[i + 1];
    b += bytes[i + 2];
    n++;
  }
  if (n == 0) return null;
  return Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
}

/// Фон полноэкранного плеера: та же обложка, растянутая и размытая, плюс
/// заливка её средним цветом — к низу сильнее (там кнопки и меню), сверху
/// почти прозрачная, чтобы картинка читалась (Alex 05–06.09.2026). Сама
/// обложка целиком рисуется отдельно виджетом [CoverArt].
class CoverBackdrop extends StatefulWidget {
  const CoverBackdrop({super.key, required this.trackId, this.localPath});

  final String trackId;
  final String? localPath;

  @override
  State<CoverBackdrop> createState() => _CoverBackdropState();
}

class _CoverBackdropState extends State<CoverBackdrop> {
  ImageProvider? _img;
  Color? _tint;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(CoverBackdrop old) {
    super.didUpdateWidget(old);
    if (old.trackId != widget.trackId || old.localPath != widget.localPath) {
      _resolve();
    }
  }

  void _resolve() {
    final img = coverImageProvider(widget.trackId, widget.localPath);
    _img = img;
    _tint = null;
    if (img == null) {
      setState(() {});
      return;
    }
    setState(() {});
    averageColorOf(img).then((c) {
      if (mounted && c != null) setState(() => _tint = c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    if (img == null) return const ColoredBox(color: Afisha.bg);
    final tint = _tint ?? Afisha.bg;
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: 28,
            sigmaY: 28,
            tileMode: TileMode.clamp,
          ),
          child: Image(
            image: img,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const ColoredBox(color: Afisha.bg),
          ),
        ),
        // Заливка под цвет обложки: плавно от почти-прозрачной сверху к
        // насыщенной снизу.
        AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                tint.withValues(alpha: 0.12),
                tint.withValues(alpha: 0.40),
                tint.withValues(alpha: 0.68),
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),
        // Небольшое общее затемнение, чтобы белый текст жил на любой обложке.
        Container(color: Colors.black.withValues(alpha: 0.18)),
      ],
    );
  }
}

/// Сама обложка — квадрат, целиком, ничего не обрезано, скруглённая. Ставится
/// в колонку (обычно в [Expanded] + [Center]), название идёт строго под ней.
class CoverArt extends StatelessWidget {
  const CoverArt({super.key, required this.trackId, this.localPath});

  final String trackId;
  final String? localPath;

  @override
  Widget build(BuildContext context) {
    final img = coverImageProvider(trackId, localPath);
    final fallback = Container(
      color: Afisha.surfaceHi,
      child: const Center(
        child: Icon(Icons.graphic_eq, color: Afisha.lime, size: 96),
      ),
    );
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: img == null
            ? fallback
            : Image(
                image: img,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
