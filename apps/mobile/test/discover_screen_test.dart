import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundflow/core/solar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/core/notice.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/features/discover/discover_screen.dart';

/// «Открытия» на телефоне (Alex TG 24.09.2026) — та же волна/плейлист, что
/// раньше жили только в окне на компьютере, теперь на телефоне. Api тут
/// подменена (без реальной сети/just_audio) — проверяем список, дни, «Убрать»
/// с отменой и переключение на плейлист по ссылке.
class _FakeApi extends Api {
  _FakeApi();

  bool dismissed = false;
  bool undismissed = false;
  bool acquired = false;

  @override
  Future<List<Map<String, dynamic>>> waveDays() async => [
        {'day': 0, 'date': '2026-09-25', 'label': 'Сегодня', 'count': 2},
        {'day': 1, 'date': '2026-09-24', 'label': 'Вчера', 'count': 1},
      ];

  int waveCalls = 0;
  int failBuildingTimes = 0;

  @override
  Future<List<Map<String, dynamic>>> wave({int day = 0, bool refresh = false}) async {
    waveCalls++;
    if (day == 0 && waveCalls <= failBuildingTimes) throw WaveBuildingException();
    if (day == 1) {
      return [
        {'artist': 'Вчерашний', 'title': 'Хит', 'album': '', 'cover_url': '', 'yandex_id': 'y2'},
      ];
    }
    return [
      {'artist': 'Radiohead', 'title': 'Let Down', 'album': 'OK Computer', 'cover_url': '', 'yandex_id': 'y1'},
      {'artist': 'Placebo', 'title': 'Special K', 'album': 'Black Market Music', 'cover_url': '', 'yandex_id': 'y3'},
    ];
  }

  @override
  Future<({String title, List<Map<String, dynamic>> items})> yandexPlaylist(String url) async {
    return (
      title: 'Мой плейлист',
      items: [
        {'artist': 'Массив', 'title': 'Плейлист-трек', 'album': '', 'cover_url': '', 'already_have': true},
      ],
    );
  }

  @override
  Future<void> discoverDismiss(String artist, String title) async => dismissed = true;

  @override
  Future<void> discoverUndismiss(String artist, String title) async => undismissed = true;

  @override
  Future<void> discoverAcquire(String artist, String title) async => acquired = true;

  // Прогресс «Скачать» (Alex TG 24.09.2026) — очередь ответов /api/acquire/log,
  // каждый следующий опрос забирает следующий элемент (последний повторяется).
  List<List<Map<String, dynamic>>> acquireLogSequence = const [];
  int _acquireLogCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> acquireLog() async {
    if (acquireLogSequence.isEmpty) return const [];
    final i = _acquireLogCalls < acquireLogSequence.length ? _acquireLogCalls : acquireLogSequence.length - 1;
    _acquireLogCalls++;
    return acquireLogSequence[i];
  }
}

Widget _app(_FakeApi api) => ProviderScope(
      overrides: [apiProvider.overrideWithValue(api)],
      child: MaterialApp(
        // Плашки «Убрано»/«Скачивание запущено» рисует NoticeHost, как в main.dart —
        // без него Notice.show() ничего не показывает в дереве виджетов теста.
        builder: (context, child) => NoticeHost(child: child ?? const SizedBox.shrink()),
        home: const DiscoverScreen(),
      ),
    );

void main() {
  testWidgets('Открытия: волна за сегодня показывает песни', (tester) async {
    await tester.pumpWidget(_app(_FakeApi()));
    await tester.pumpAndSettle();

    // Название сверху, исполнитель снизу (26.09.2026, раньше «Исполнитель — Название» + альбом).
    expect(find.text('Let Down'), findsOneWidget);
    expect(find.text('Radiohead'), findsOneWidget);
    expect(find.text('Special K'), findsOneWidget);
  });

  testWidgets('Открытия: переключение на «Вчера» грузит другой список', (tester) async {
    await tester.pumpWidget(_app(_FakeApi()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Вчера'));
    await tester.pumpAndSettle();

    expect(find.text('Хит'), findsOneWidget);
    expect(find.textContaining('Radiohead'), findsNothing);
  });

  testWidgets('Открытия: «Убрать» прячет строку и предлагает «Вернуть»', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    // «Убрать» — свайпом строки влево (кнопки ✕ больше нет).
    await tester.drag(find.text('Let Down'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(api.dismissed, isTrue);
    expect(find.text('Вернуть'), findsOneWidget);

    await tester.tap(find.text('Вернуть'));
    await tester.pumpAndSettle();
    expect(api.undismissed, isTrue);
  });

  testWidgets('Открытия: «Скачать» показывает прогресс, а не просто уходит в тишину',
      (tester) async {
    // Alex TG 24.09.2026: «нет прогресс бара, качается ли, что делает» —
    // сразу спиннер вместо иконки, опрос лога догоняет статус компьютера.
    final api = _FakeApi()
      ..acquireLogSequence = [
        [
          {'artist': 'Radiohead', 'title': 'Let Down', 'state': 'running', 'note': 'качаю…'},
        ],
        [
          {'artist': 'Radiohead', 'title': 'Let Down', 'state': 'done', 'note': 'скачано'},
        ],
      ];
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Скачать').first);
    await tester.pump(); // мгновенный оптимистичный спиннер, без ожидания сети

    expect(api.acquired, isTrue);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.byTooltip('Скачать'), findsOneWidget); // остался только у второй песни

    await tester.pump(const Duration(seconds: 4)); // первый опрос лога — всё ещё «качаю»
    expect(find.text('качаю…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4)); // второй опрос — «done»
    await tester.pumpAndSettle();

    expect(find.byIcon(SolarBold.checkCircle), findsOneWidget);
    expect(find.text('качаю…'), findsNothing);
  });

  testWidgets('Открытия: ссылка на плейлист показывает его песни вместо волны', (tester) async {
    await tester.pumpWidget(_app(_FakeApi()));
    await tester.pumpAndSettle();

    // Ссылка — под значком 🔗 вверху: шторка с полем (клавиатура сразу) и «Показать».
    await tester.tap(find.byTooltip('Плейлист по ссылке'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://music.yandex.ru/users/x/playlists/1');
    await tester.tap(find.text('Показать'));
    await tester.pumpAndSettle();

    expect(find.text('Плейлист-трек'), findsOneWidget);
    expect(find.text('Мой плейлист'), findsOneWidget); // заголовок AppBar
    // Уже есть в каталоге — не кнопка «Скачать», а галочка.
    expect(find.byTooltip('Скачать'), findsNothing);

    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.text('Открытия'), findsOneWidget);
  });

  // Регрессия 24.09.2026: первый заход за сегодняшнюю волну (кэша ещё нет)
  // реально собирается на компьютере — до этого фикса телефон Alex сдавался
  // ждать раньше, чем компьютер заканчивал, и показывал «Компьютер
  // недоступен» на пустом месте. Теперь — «собирает, подождите» и сама
  // повторная попытка, без участия Alex.
  testWidgets('Открытия: «уже собирается» — сама ждёт и повторяет, не ошибка',
      (tester) async {
    final api = _FakeApi()..failBuildingTimes = 2;
    await tester.pumpWidget(_app(api));
    await tester.pump(); // первый неудачный заход (WaveBuildingException)

    expect(find.textContaining('собирает подборку'), findsOneWidget);
    expect(find.text('Let Down'), findsNothing);

    await tester.pump(const Duration(seconds: 9)); // вторая попытка (тоже неудачная)
    expect(find.textContaining('собирает подборку'), findsOneWidget);

    await tester.pump(const Duration(seconds: 9)); // третья попытка — успех
    await tester.pumpAndSettle();

    expect(find.textContaining('собирает подборку'), findsNothing);
    expect(find.text('Let Down'), findsOneWidget);
    expect(api.waveCalls, 3);
  });
}
