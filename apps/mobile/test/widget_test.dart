import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_offer.dart';
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/main.dart';

class _FakeApi extends Api {
  _FakeApi();
  @override
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async => [
        {'id': 'test-tone', 'title': 'Тестовый тон 440 Гц', 'artist': 'SoundFlow'},
      ];
  @override
  Future<Map<String, dynamic>> adminStatus() async => {
        'db': 'ok',
        'uptime_sec': 12,
        'go_version': 'go1.25',
        'music_source': 'тестовые тоны',
        'migrations': ['0001_sync.sql', '0002_catalog.sql'],
        'catalog': {'tracks': 0, 'track_files': 0},
        'events': {'total': 0, 'by_kind': {}},
        'devices': 0,
      };
  @override
  Future<List<Map<String, dynamic>>> adminDevices() async => const [];
  @override
  Future<List<Map<String, dynamic>>> adminEvents({int limit = 20}) async => const [];
  @override
  Future<List<Map<String, dynamic>>> searchCatalog(String q) async => const [];
}

// В testWidgets крутится FakeAsync — фоновый изолят sqflite не отвечает.
// NoIsolate-фабрика гоняет SQLite в этом же потоке, поэтому await не виснет.
Future<Widget> _app() async {
  final api = _FakeApi();
  final db = await Db.open(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
  final sync = SyncRepo(api, db);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      dbProvider.overrideWithValue(db),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(PlayerController()),
      syncProvider.overrideWithValue(sync),
      syncOfferProvider.overrideWithValue(SyncOffer(DownloadsRepo(api, db, sync))),
    ],
    child: const SoundFlowApp(),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('старт без входа — три вкладки, без Чартов', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    expect(find.text('Войти'), findsNothing);
    expect(find.text('Чарты'), findsNothing);
    expect(find.text('Альбомы'), findsNothing);
    for (final label in ['Поток', 'Моя музыка', 'Профиль']) {
      expect(find.text(label), findsWidgets, reason: 'нет вкладки $label');
    }
  });

  testWidgets('вкладка «Моя музыка»: пустой список без ошибок', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Моя музыка'));
    await tester.pumpAndSettle();

    expect(find.textContaining('На телефоне пока пусто'), findsOneWidget);
    // Вид «Б» (20.09.2026): в шапке только число песен, без исполнителей и гигабайтов.
    expect(find.text('0 песен на телефоне'), findsOneWidget);
    expect(find.textContaining('МБ'), findsNothing);
  });

  testWidgets('мини-плеер скрыт, пока ничего не играет', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  // 26.09.2026 (разбор Gemini «Профиль», Alex «да»): «Сервер» и «Настройки» слиты в один
  // экран «Связь с домом»; на нём состояние, «История и оценки», адрес, удалённый доступ и
  // «Полный сброс» внизу. Экран с пульсирующей точкой — pumpAndSettle не дождётся конца
  // анимации, поэтому листаем кадры вручную.
  Future<void> openHome(WidgetTester tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Связь с домом'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('в Профиле одна строка «Связь с домом» вместо «Сервер» и «Настройки»', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Связь с домом'), findsOneWidget);
    expect(find.text('Сервер'), findsNothing);
    expect(find.text('Настройки'), findsNothing);
    expect(find.text('Убранные'), findsNothing);
    expect(find.text('Скачать музыку'), findsNothing);
  });

  testWidgets('в Профиле карточка «Медиатека»', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Медиатека'), findsOneWidget);
    expect(find.text('Музыка с компьютера'), findsNothing);
  });

  testWidgets('«Связь с домом»: состояние, история, адрес, удалённый доступ, без журнала', (tester) async {
    await openHome(tester);
    expect(find.text('История и оценки'), findsOneWidget);
    expect(find.text('всё передано'), findsOneWidget);
    expect(find.text('Адрес дома'), findsOneWidget);
    expect(find.text('Удалённый доступ'), findsOneWidget);
    expect(find.text('Журнал'), findsNothing);
    expect(find.text('Синхронизировать сейчас'), findsNothing);
  });
}
