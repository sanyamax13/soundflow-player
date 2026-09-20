import 'package:flutter/material.dart';

final RegExp _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// Одна-две буквы для плитки: первые буквы первых двух слов имени
/// («Depeche Mode» → «DM», «A-Ha» → «AH», «Земляне» → «З»). Совсем без букв —
/// нота.
String initialsOf(String name) {
  final words = [for (final m in _word.allMatches(name).take(2)) m.group(0)!];
  if (words.isEmpty) return '♪';
  return [for (final w in words) String.fromCharCode(w.runes.first)].join().toUpperCase();
}

/// Цвет плитки для имени: одно имя — всегда один цвет (по хэшу), тёмный и
/// негромкий, чтобы белые буквы читались, а список не пестрил.
Color tileColorFor(String name) {
  var h = 0;
  for (final c in name.trim().toLowerCase().codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.42, 0.30).toColor();
}

/// Плитка вместо серой ноты, когда у песни/исполнителя нет обложки (Alex
/// 20.09.2026, «Моя музыка»: «серая нота у большинства — некрасиво»).
class LetterTile extends StatelessWidget {
  const LetterTile({super.key, required this.name, this.size = 48, this.radius = 12});

  final String name;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tileColorFor(name),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Text(
          initialsOf(name),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.95),
            fontWeight: FontWeight.w700,
            fontSize: size * 0.34,
          ),
        ),
      );
}
