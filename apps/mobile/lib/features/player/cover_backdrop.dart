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

/// Фон полноэкранного плеера: та же обложка, растянутая и размытая, поверх —
/// ровное тёмное затемнение, чтобы белый текст читался на любой картинке.
/// Заливку «под цвет обложки» (Tidal-стиль) убрали по просьбе Alex 06.09.2026 —
/// цвет мазал под тон обложки и мешал. Сама обложка целиком рисуется отдельно
/// виджетом [CoverArt].
class CoverBackdrop extends StatelessWidget {
  const CoverBackdrop({super.key, required this.trackId, this.localPath});

  final String trackId;
  final String? localPath;

  @override
  Widget build(BuildContext context) {
    final img = coverImageProvider(trackId, localPath);
    if (img == null) return const ColoredBox(color: Afisha.bg);
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
        Container(color: Colors.black.withValues(alpha: 0.34)),
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
