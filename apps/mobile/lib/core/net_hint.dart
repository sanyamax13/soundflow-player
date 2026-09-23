import 'package:flutter/material.dart';

import '../features/profile/server_url_screen.dart';
import 'notice.dart';

/// Единая подсказка для всех мест «сервер не ответил» (Опус-ревью телефона
/// 14.09.2026, пункт 1): раньше ошибка была тупиком — без причины и без
/// действия. Причина всегда одна и та же (docs/RULES.md §1): комп отвечает,
/// только пока на нём открыто окно программы SoundFlow.
const String kServerUnreachableHint =
    'Откройте окно SoundFlow на компьютере — телефон отвечает только пока оно открыто.';

/// Показать плашку «сервер не ответил» с подсказкой и кнопкой «Проверить
/// связь» (ведёт на экран адреса сервера, там же можно найти его заново).
/// [lead] — короткое пояснение, что именно не получилось (например, «Радио
/// не собралось»); без него — просто «Сервер не ответил».
void showServerUnreachable({String? lead}) {
  Notice.show(
    lead ?? 'Сервер не ответил',
    subtitle: kServerUnreachableHint,
    kind: NoticeKind.error,
    duration: const Duration(seconds: 7),
    actions: [
      NoticeAction('Проверить связь', () {
        rootNavigatorKey.currentState?.push(
          MaterialPageRoute<void>(builder: (_) => const ServerUrlScreen()),
        );
      }),
    ],
  );
}
