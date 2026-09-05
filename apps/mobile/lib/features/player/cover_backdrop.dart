import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/theme.dart';

/// Обложка для полноэкранного плеера — вариант «с размытым фоном» (выбор
/// Alex, 05.09.2026). Целая обложка по центру, ничего не обрезано; фон —
/// её же увеличенная размытая копия, без чёрных полей. Раньше обложка
/// растягивалась на весь экран (`BoxFit.cover`) и у квадратных обложек
/// срезались края — «не по центру».
///
/// Один виджет на два места: играющий трек в [PlayerView] и превью песни
/// на стартовом экране «Потока».
class CoverBackdrop extends StatelessWidget {
  const CoverBackdrop({super.key, required this.trackId, this.localPath});

  /// id трека — по нему собирается сетевой адрес обложки на сервере.
  final String trackId;

  /// Локальный файл обложки (у скачанных треков) — если есть, берём его,
  /// в сеть не ходим.
  final String? localPath;

  ImageProvider? _provider() {
    final p = localPath;
    if (p != null && p.isNotEmpty && File(p).existsSync()) {
      return FileImage(File(p));
    }
    final url = coverUrlFor(trackId);
    return url.isEmpty ? null : NetworkImage(url);
  }

  @override
  Widget build(BuildContext context) {
    final img = _provider();
    if (img == null) {
      return Container(
        color: Afisha.surfaceHi,
        child: const Center(
          child: Icon(Icons.graphic_eq, color: Afisha.lime, size: 96),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // Фон — та же обложка, растянутая на весь экран и размытая.
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
        // Приглушаем фон, чтобы передняя обложка и текст читались.
        Container(color: Colors.black.withValues(alpha: 0.3)),
        // Целая обложка по центру (чуть выше середины — ниже неё название
        // и кнопки).
        Align(
          alignment: const Alignment(0, -0.28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image(
                  image: img,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
