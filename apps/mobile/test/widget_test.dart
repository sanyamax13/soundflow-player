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

    expect(find.textContaining('Пока ничего не скачано'), findsOneWidget);
    // «Полка» (06.09.2026): шапка со счётчиком исполнителей, без строки «Обложки».
    expect(find.text('0 исполнителей · 0 песен · 0.0 МБ'), findsOneWidget);
  });

  testWidgets('мини-плеер скрыт, пока ничего не играет', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  testWidgets('Синхронизация свёрнута в экран «Сервер» (06.09.2026)', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    // Отдельной карточки «Синхронизация» в Профиле больше нет.
    expect(find.text('Синхронизация'), findsNothing);

    await tester.tap(find.text('Сервер'));
    await tester.pumpAndSettle();
    expect(find.text('Всё отправлено'), findsOneWidget);
    expect(find.text('Синхронизировать сейчас'), findsOneWidget);
  });

  // Экран «Сервер» упрощён (Опус-ревью телефона 14.09.2026, пункт 8): вместо
  // версий/миграций/устройств/сырого лога — связь, синхронизация, «больше не
  // качать».
  testWidgets('в Профиле есть «Сервер», экран показывает состояние', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Сервер'), findsOneWidget);

    await tester.tap(find.text('Сервер'));
    await tester.pumpAndSettle();
    expect(find.text('СИНХРОНИЗАЦИЯ'), findsOneWidget);
    expect(find.text('СВЯЗЬ С КОМПЬЮТЕРОМ'), findsOneWidget);
    expect(find.text('БОЛЬШЕ НЕ КАЧАТЬ'), findsOneWidget);
    expect(find.text('Компьютер на связи'), findsOneWidget);
  });

  testWidgets('в Профиле есть «Скачать музыку», кнопка «докачать ещё» на месте', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Скачать музыку'), findsOneWidget);

    await tester.tap(find.text('Скачать музыку'));
    await tester.pumpAndSettle();
    expect(find.text('Скачано: 0 песен, 0 Б'), findsOneWidget);
    expect(find.text('Докачать ещё 10 ГБ'), findsOneWidget);
  });

  testWidgets('в Профиле есть «Убранные», пустая — понятная надпись', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Убранные'), findsOneWidget);

    await tester.tap(find.text('Убранные'));
    await tester.pumpAndSettle();
    expect(find.text('Пока ничего не убрано'), findsOneWidget);
  });
}
