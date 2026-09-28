import 'dart:io';

import 'package:flutter/material.dart';
import '../../core/solar.dart';

import '../../core/config.dart';
import '../../core/letter_tile.dart';
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
  const CoverArt({super.key, required this.trackId, this.localPath, this.artist});

  final String trackId;
  final String? localPath;

  /// Для заглушки, когда обложки нет нигде: цветной градиент исполнителя и его буквы.
  final String? artist;

  @override
  Widget build(BuildContext context) {
    final img = coverImageProvider(trackId, localPath);
    final a = artist?.trim() ?? '';
    final fallback = a.isEmpty
        ? Container(
            color: Afisha.surfaceHi,
            child: const Center(
              child: Icon(SolarBold.soundwave, color: Afisha.lime, size: 96),
            ),
          )
        : _ArtistCover(artist: a);
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

/// Заглушка вместо серого квадрата (27.09.2026, Alex «делай так»): градиент в цвете исполнителя
/// (у каждого свой, как плитки в «Моей музыке» — tileColorFor) и его буквы крупно. Одна и та же
/// у всех его песен без обложки.
class _ArtistCover extends StatelessWidget {
  const _ArtistCover({required this.artist});
  final String artist;

  @override
  Widget build(BuildContext context) {
    final base = HSLColor.fromColor(tileColorFor(artist));
    final top = base.withLightness(0.46).withSaturation(0.55).toColor();
    final bottom = base.withHue((base.hue + 40) % 360).withLightness(0.16).withSaturation(0.5).toColor();
    return LayoutBuilder(
      builder: (context, c) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [top, bottom]),
        ),
        child: Center(
          child: Text(
            initialsOf(artist),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: c.maxWidth * 0.34,
              fontWeight: FontWeight.w700,
              letterSpacing: -2,
            ),
          ),
        ),
      ),
    );
  }
}
