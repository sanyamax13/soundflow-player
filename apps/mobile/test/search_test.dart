import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/features/search/search_screen.dart';

class _FakeApi extends Api {
  _FakeApi({this.catalog = const [], this.onAcquire});

  final List<Map<String, dynamic>> catalog;
  final Future<Map<String, dynamic>> Function()? onAcquire;

  @override
  Future<List<Map<String, dynamic>>> searchCatalog(String q) async {
    if (q.isEmpty) return catalog;
    final needle = q.toLowerCase();
    return catalog
        .where((t) => '${t['title']} ${t['artist']}'.toLowerCase().contains(needle))
        .toList();
  }

  @override
  Future<Map<String, dynamic>> acquireTrack({
    required String artist,
    required String title,
    int durationSec = 0,
  }) {
    final f = onAcquire;
    if (f == null) throw AcquireException('нет качалки');
    return f();
  }
}

Future<Widget> _harness(_FakeApi api) async {
  final db = await Db.open(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
  final sync = SyncRepo(api, db);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(PlayerController()),
      syncProvider.overrideWithValue(sync),
    ],
    child: const MaterialApp(home: SearchScreen()),
  );
}

Future<void> _fill(WidgetTester tester, String artist, String title) async {
  await tester.enterText(find.byType(TextField).at(0), artist);
  await tester.enterText(find.byType(TextField).at(1), title);
}

Future<void> _tapAndPump(WidgetTester tester) async {
  await tester.tap(find.text('Найти и скачать'));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('оба блока на месте, каталог пуст', (tester) async {
    await tester.pumpWidget(await _harness(_FakeApi()));
    await tester.pumpAndSettle();

    expect(find.text('ЗАКАЗАТЬ НОВОЕ'), findsOneWidget);
    expect(find.text('УЖЕ НА СЕРВЕРЕ'), findsOneWidget);
    expect(find.text('Найти и скачать'), findsOneWidget);
    expect(find.text('В каталоге пока пусто'), findsOneWidget);
  });

  testWidgets('каталог с треками — строки видны', (tester) async {
    await tester.pumpWidget(await _harness(_FakeApi(catalog: [
      {'id': 't1', 'title': 'Пачка сигарет', 'artist': 'Кино'},
    ])));
    await tester.pumpAndSettle();

    expect(find.text('Пачка сигарет'), findsOneWidget);
    expect(find.text('Кино'), findsOneWidget);
  });

  testWidgets('заказ не удался — показывает причину', (tester) async {
    await tester.pumpWidget(await _harness(_FakeApi(
      onAcquire: () async => throw AcquireException('Не нашлось ни в одном источнике'),
    )));
    await tester.pumpAndSettle();

    await _fill(tester, 'Кино', 'Нечто, чего нет');
    await _tapAndPump(tester);

    expect(find.text('Не нашлось ни в одном источнике'), findsOneWidget);
  });

  testWidgets('заказ удался — показывает подтверждение', (tester) async {
    await tester.pumpWidget(await _harness(_FakeApi(
      onAcquire: () async => {'track_id': 't_x', 'created': true, 'source': 'yandex'},
    )));
    await tester.pumpAndSettle();

    await _fill(tester, 'Кино', 'Пачка сигарет');
    await tester.tap(find.text('Найти и скачать'));
    await tester.pump();
    // Подтягивание файла на телефон в тесте недоступно (нет плагина путей) —
    // даём реальному async завершиться и отрисоваться.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Добавлено на сервер'), findsOneWidget);
  });
}
