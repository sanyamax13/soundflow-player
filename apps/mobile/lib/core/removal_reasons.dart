import 'package:flutter/material.dart';

import 'theme.dart';

/// Причины «Убрать совсем» — раньше было пять («Не нравится», «Плохое
/// качество», «Это не музыка», «Надоела», «Другая причина»), плюс отдельная
/// «Не та версия» удаляла файл сразу вообще без вопроса о причине — вместе с
/// «меньше такого» и «скрыть исполнителя» получалась куча похожих кнопок,
/// разницу между которыми Alex не мог увидеть на экране (Опус-ревью телефона
/// 14.09.2026, пункт 9). Просто «не нравится»/«надоела» — это теперь «меньше
/// такого» (не трогает файл, только сигнал на будущее). Здесь остались
/// причины УДАЛИТЬ файл — объективные: плохой файл/не та версия, или не
/// музыка вовсе.
const kRemovalReasons = <String, String>{
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
