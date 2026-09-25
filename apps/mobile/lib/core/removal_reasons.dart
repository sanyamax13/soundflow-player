import 'package:flutter/material.dart';

import 'apple.dart';
import 'theme.dart';

/// Причины «Убрать совсем» — 14.09.2026 (Опус-ревью телефона, пункт 9)
/// пробовали убрать отсюда «Не нравится» вовсе (перенести смысл в «меньше
/// такого», которая не трогает файл) — Alex в ту же ночь вернул: ему нужно,
/// чтобы «не нравится» именно СТИРАЛА трек с телефона и с сервера, как и
/// остальные причины здесь (delete() ниже это уже делает для любой причины —
/// текст причины на поведение не влияет, только на подпись в списке).
///
/// «Другая причина» убрана (Alex TG 25.09.2026) — три чётких варианта
/// достаточно, лишний пункт без выбора конкретики не нёс пользы.
const kRemovalReasons = <String, String>{
  'dislike': 'Не нравится',
  'bad_quality': 'Плохое качество или не та версия',
  'not_music': 'Это не музыка (подкаст, интервью)',
};

/// Показать лист выбора причины удаления — общий и для плеера, и для «Моей
/// музыки» (одно и то же действие, один и тот же список). null — отменил.
/// Оформление — стекло (apple.dart, AppleSection/AppleRow) + отдельная кнопка
/// «Отмена» фирменным лаймом снизу (Alex TG 25.09.2026 — из четырёх
/// показанных вариантов выбрал этот, «синтез iOS 27 + One UI»).
Future<String?> pickRemovalReason(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Причина удаления',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: Afisha.ink,
                  ),
                ),
              ),
            ),
            AppleSection(
              dividerInset: 16,
              children: [
                for (final e in kRemovalReasons.entries)
                  AppleRow(
                    title: e.value,
                    destructive: true,
                    onTap: () => Navigator.pop(ctx, e.key),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: Material(
                color: Afisha.lime,
                borderRadius: BorderRadius.circular(24),
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => Navigator.pop(ctx, null),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Отмена',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Colors.black,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
