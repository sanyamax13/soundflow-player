import 'dart:io';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Обложка трека — квадратная картинка со скруглёнными углами. Локальный
/// файл (уже скачанная песня) — приоритет; ссылка на сервер (ещё не
/// скачано, показываем в поиске/каталоге) — вторым делом; ни того ни
/// другого или файл/загрузка не вышли — серый плейсхолдер с нотой,
/// как было раньше везде.
class CoverThumb extends StatelessWidget {
  const CoverThumb({super.key, this.path, this.url, this.size = 44, this.radius = 6});

  final String? path;
  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    Widget child;
    final p = path;
    final u = url;
    if (p != null && p.isNotEmpty && File(p).existsSync()) {
      child = Image.file(File(p), width: size, height: size, fit: BoxFit.cover);
    } else if (u != null && u.isNotEmpty) {
      child = Image.network(
        u,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(),
        loadingBuilder: (context, child, progress) => progress == null ? child : _placeholder(),
      );
    } else {
      child = _placeholder();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: size, height: size, child: child),
    );
  }

  Widget _placeholder() => Container(
        color: Afisha.surfaceHi,
        child: Icon(Icons.music_note, color: Afisha.inkDim, size: size * 0.5),
      );
}
