import 'dart:io';

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

/// Сама обложка — квадрат, скруглённая, картинка заполняет его целиком (не
/// квадратная — обрезается по краям, как в Apple Music/Spotify). Раньше была
/// `BoxFit.contain`: не квадратная обложка оставляла по бокам полоски фона
/// плитки, а тень под ней рисовала «парящий предмет» шире реальной картинки
/// — нечестно (Опус-ревью «Поток» 23.09.2026, пункт 8). Ставится в колонку
/// (обычно в [Expanded] + [Center]), название идёт строго под ней.
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
      // Тот же радиус, что и у карточки-обёртки в player_view.dart (20) —
      // было 12, третье своё число среди похожих скруглений экрана
      // (Опус-ревью «Поток» 23.09.2026, пункт 11).
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: img == null
            ? fallback
            : Image(
                image: img,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback,
                // Пока грузится (или НАВСЕГДА нет обложки — сервер честно
                // отвечает 404, errorBuilder сработает не сразу) — заглушка
                // сразу, не пустой квадрат (Alex TG 24.09.2026, скриншот:
                // «Серые глаза» без обложки — квадрат был пустым, не нота).
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : fallback,
              ),
      ),
    );
  }
}
