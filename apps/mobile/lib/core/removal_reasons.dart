import 'package:flutter/material.dart';

import 'theme.dart';

/// Причины «Убрать совсем» — 14.09.2026 (Опус-ревью телефона, пункт 9)
/// пробовали убрать отсюда «Не нравится» вовсе (перенести смысл в «меньше
/// такого», которая не трогает файл) — Alex в ту же ночь вернул: ему нужно,
/// чтобы «не нравится» именно СТИРАЛА трек с телефона и с сервера, как и
/// остальные причины здесь (delete() ниже это уже делает для любой причины —
/// текст причины на поведение не влияет, только на подпись в списке).
const kRemovalReasons = <String, String>{
  'dislike': 'Не нравится',
  'bad_quality': 'Плохое качество или не та версия',
  'not_music': 'Это не музыка (подкаст, интервью)',
  'other': 'Другая причина',
};

/// Показать лист выбора причины удаления — общий и для плеера, и для «Моей
/// музыки» (одно и то же действие, один и тот же список). null — отменил.
Future<String?> pickRemovalReason(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Afisha.surfaceHi,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Почему убираешь совсем?',
                  style: TextStyle(
                      color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
          for (final e in kRemovalReasons.entries)
            ListTile(
              title: Text(e.value, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, e.key),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
