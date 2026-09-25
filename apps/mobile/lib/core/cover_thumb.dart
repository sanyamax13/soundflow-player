import 'dart:io';

import 'package:flutter/material.dart';

import 'letter_tile.dart';
import 'theme.dart';

/// Обложка трека — квадратная картинка со скруглёнными углами. Локальный
/// файл (уже скачанная песня) — приоритет; ссылка на сервер (ещё не
/// скачано, показываем в поиске/каталоге) — вторым делом; ни того ни
/// другого или файл/загрузка не вышли — серый плейсхолдер с нотой,
/// как было раньше везде; если передан [label] (имя исполнителя) — вместо ноты
/// цветная плитка с его буквами (`LetterTile`, «Моя музыка» 20.09.2026).
class CoverThumb extends StatelessWidget {
  const CoverThumb({super.key, this.path, this.url, this.size = 44, this.radius = 6, this.label});

  final String? path;
  final String? url;
  final double size;
  final double radius;
  final String? label;

  @override
  Widget build(BuildContext context) {
    Widget child;
    final p = path;
    final u = url;
    // Раскодировать обложку сразу до размера плитки (в точках экрана), а не целиком:
    // на диске они 600×600, а сгенерированные — 1024×1024 (мегабайты в памяти на
    // каждую), плитка же 44–76 точек. Быстрее прокрутка, кэш картинок вмещает
    // в разы больше (21.09.2026, Alex TG 20331).
    final px = size.isFinite
        ? (size * (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0)).round()
        : null;
    if (p != null && p.isNotEmpty && File(p).existsSync()) {
      child = Image.file(File(p), width: size, height: size, fit: BoxFit.cover, cacheWidth: px);
    } else if (u != null && u.isNotEmpty) {
      child = Image.network(
        u,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: px,
        errorBuilder: (_, _, _) => _placeholder(),
        loadingBuilder: (context, child, progress) => progress == null ? child : _placeholder(),
      );
    } else {
      child = _placeholder();
    }
    // 25.09.2026 (по разбору Gemini, Alex «да меняй»): было ClipRRect —
    // обычное скругление. «Сквирк» (суперэллипс) через ContinuousRectangleBorder
    // выглядит мягче, ближе к iOS-иконкам.
    return ClipPath(
      clipper: ShapeBorderClipper(shape: ContinuousRectangleBorder(borderRadius: BorderRadius.circular(radius))),
      child: SizedBox(width: size, height: size, child: child),
    );
  }

  Widget _placeholder() {
    final l = label;
    if (l != null && l.trim().isNotEmpty) return LetterTile(name: l, size: size, radius: 0);
    return Container(
      color: Afisha.surfaceHi,
      child: Icon(Icons.music_note, color: Afisha.inkDim, size: size * 0.5),
    );
  }
}
