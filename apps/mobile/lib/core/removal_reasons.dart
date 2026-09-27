import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'glass_sheet.dart';
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
/// музыки» (одно и то же действие, один и тот же список). null — отменил,
/// '' — «Без причины».
///
/// 27.09.2026 (разбор Gemini и Алисы, Alex «делай»): общий стеклянный вид шторок
/// (glass_sheet.dart); первой строкой «Без причины» — удалить одним нажатием, не
/// выбирая; «Отмена» лаймом внизу — палец идёт к безопасному.
Future<String?> pickRemovalReason(BuildContext context) {
  return showGlassSheet<String>(
    context,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GlassSheetTitle('Удалить песню', body: 'Сотрётся с телефона и с компьютера насовсем.'),
        _reasonRow(ctx, 'Без причины', ''),
        for (final e in kRemovalReasons.entries) _reasonRow(ctx, e.value, e.key),
        const SizedBox(height: 12),
        GlassSheetButton(label: 'Отмена', kind: GlassButtonKind.lime, onTap: () => Navigator.pop(ctx)),
      ],
    ),
  );
}

Widget _reasonRow(BuildContext ctx, String label, String value) => InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        HapticFeedback.heavyImpact();
        Navigator.pop(ctx, value);
      },
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            const SizedBox(width: 8),
            const Icon(Icons.delete_outline, color: Afisha.red, size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: Afisha.red)),
            ),
          ],
        ),
      ),
    );
