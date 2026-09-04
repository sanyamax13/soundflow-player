import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/main.dart';

class _FakeApi extends Api {
  _FakeApi();
  @override
  Future<List<Map<String, dynamic>>> tracks() async => [
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
  return SoundFlowApp(
    api: api,
    downloads: DownloadsRepo(api, db, sync),
    player: PlayerController(),
    sync: sync,
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

    expect(find.text('Пока ничего не скачано'), findsOneWidget);
    expect(find.text('0 песен · 0.0 МБ'), findsOneWidget);
  });

  testWidgets('мини-плеер скрыт, пока ничего не играет', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  testWidgets('в Профиле есть карточка «Синхронизация»', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Синхронизация'), findsOneWidget);

    await tester.tap(find.text('Синхронизация'));
    await tester.pumpAndSettle();
    expect(find.text('Всё отправлено'), findsOneWidget);
    expect(find.text('Синхронизировать сейчас'), findsOneWidget);
  });

  testWidgets('в Профиле есть «Сервер», экран показывает состояние', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Сервер'), findsOneWidget);

    await tester.tap(find.text('Сервер'));
    await tester.pumpAndSettle();
    expect(find.text('КАТАЛОГ'), findsOneWidget);
    expect(find.text('на связи'), findsOneWidget);
    expect(find.text('пока никто не синхронизировался'), findsOneWidget);
  });
}
