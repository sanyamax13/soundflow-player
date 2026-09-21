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
    // Кнопки «Синхронизировать сейчас» больше нет: события уходят сами, а
    // песни телефон предлагает скачать карточкой (Alex TG 20158, 20167).
    expect(find.text('Синхронизировать сейчас'), findsNothing);
  });

  // Экран «Сервер» упрощён (Опус-ревью телефона 14.09.2026, пункт 8): вместо
  // версий/миграций/устройств/сырого лога — связь и синхронизация. Список
  // «больше не качать» с 19.09.2026 на телефоне не показывается (Alex TG 19943).
  testWidgets('в Профиле есть «Сервер», экран показывает состояние', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Сервер'), findsOneWidget);

    await tester.tap(find.text('Сервер'));
    await tester.pumpAndSettle();
    expect(find.text('Что уходит на компьютер'), findsOneWidget);
    expect(find.text('Связь с компьютером'), findsOneWidget);
    expect(find.text('Больше не качать'), findsNothing);
    expect(find.text('Компьютер на связи'), findsOneWidget);
  });

  testWidgets('в Профиле вместо «Скачать музыку» — строка «Музыка с компьютера»', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Скачать музыку'), findsNothing);
    expect(find.text('Музыка с компьютера'), findsOneWidget);
  });

  // Alex TG 19943 (19.09.2026): «убранные только в программе на сервере, а не в
  // плеере на телефоне, плеер захламляется информацией».
  testWidgets('в Профиле нет «Убранных»', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Убранные'), findsNothing);
    expect(find.text('Скачать музыку'), findsNothing);
    expect(find.text('Сервер'), findsOneWidget);
  });

  // «Адрес сервера» переехал из Профиля в Настройки (Alex TG 14.09.2026: «в
  // профиле только статистику, остальное — в настройки»); журнал живёт там же.
  testWidgets('в Профиле «Настройки» ведут на адрес сервера и журнал', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Адрес сервера'), findsNothing);

    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Адрес сервера'), findsOneWidget);
    expect(find.text('Журнал'), findsOneWidget);
  });
}
