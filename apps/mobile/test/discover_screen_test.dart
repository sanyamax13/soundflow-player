import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  @override
  Future<List<Map<String, dynamic>>> wave({int day = 0, bool refresh = false}) async {
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

    expect(find.textContaining('Radiohead — Let Down'), findsOneWidget);
    expect(find.textContaining('Placebo — Special K'), findsOneWidget);
  });

  testWidgets('Открытия: переключение на «Вчера» грузит другой список', (tester) async {
    await tester.pumpWidget(_app(_FakeApi()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Вчера'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Вчерашний — Хит'), findsOneWidget);
    expect(find.textContaining('Radiohead'), findsNothing);
  });

  testWidgets('Открытия: «Убрать» прячет строку и предлагает «Вернуть»', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Убрать').first);
    await tester.pumpAndSettle();

    expect(api.dismissed, isTrue);
    expect(find.text('Вернуть'), findsOneWidget);

    await tester.tap(find.text('Вернуть'));
    await tester.pumpAndSettle();
    expect(api.undismissed, isTrue);
  });

  testWidgets('Открытия: «Скачать» запускает заказ на компьютере', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Скачать').first);
    await tester.pumpAndSettle();

    expect(api.acquired, isTrue);
    expect(find.textContaining('Скачивание запущено'), findsOneWidget);
  });

  testWidgets('Открытия: ссылка на плейлист показывает его песни вместо волны', (tester) async {
    await tester.pumpWidget(_app(_FakeApi()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'https://music.yandex.ru/users/x/playlists/1');
    await tester.tap(find.text('Показать'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Массив — Плейлист-трек'), findsOneWidget);
    expect(find.text('Мой плейлист'), findsOneWidget); // заголовок AppBar
    // Уже есть в каталоге — не кнопка «Скачать», а галочка.
    expect(find.byTooltip('Скачать'), findsNothing);

    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.text('Открытия'), findsOneWidget);
  });
}
