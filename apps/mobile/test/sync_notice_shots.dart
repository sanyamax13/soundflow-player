// Рендер НАСТОЯЩИХ экранов с новой плашкой (как на iPhone) и карточкой «что ждёт
// на компьютере» (20.09.2026, Alex TG 20158/20167) в PNG — для показа перед
// сборкой. Не проверка логики. Запуск:
//   flutter test --update-goldens test/sync_notice_shots.dart
// Картинки: test/goldens/sync_*.png
// Имя без суффикса _test → обычный `flutter test` его не подхватывает.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/core/notice.dart';
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
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async => const [];
}

class _QuietPlayer extends PlayerController {
  @override
  Future<void> playQueue(
    List<NowPlaying> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    bool loop = true,
    bool autoplay = true,
  }) async {}
}

Future<void> _loadFonts() async {
  final loader = FontLoader('Inter');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    final f = File('assets/fonts/Inter-$w.ttf');
    if (f.existsSync()) loader.addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)));
  }
  await loader.load();
  for (final p in [
    r'E:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    r'E:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
  ]) {
    final f = File(p);
    if (f.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)))).load();
      break;
    }
  }
}

const _mb = 1024 * 1024;
const _gb = 1024 * _mb;

const _songs = [
  ['Кино', 'Группа крови'], ['Кино', 'Звезда по имени Солнце'], ['Кино', 'Спокойная ночь'],
  ['Depeche Mode', 'Personal Jesus'], ['Depeche Mode', 'Enjoy the Silence'],
  ['Земфира', 'Искала'], ['Земфира', 'Почему'],
  ['Би-2', 'Полковнику никто не пишет'], ['Ленинград', 'Экспонат'],
  ['Наутилус Помпилиус', 'Скованные одной цепью'], ['Nirvana', 'Smells Like Teen Spirit'],
  ['Queen', 'Bohemian Rhapsody'], ['ДДТ', 'Осенняя'], ['Аквариум', 'Город золотой'],
];

Future<(Widget, SyncOffer, Db)> _app(WidgetTester tester, {PlayerController? player}) async {
  final api = _FakeApi();
  final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  await tester.runAsync(() async {
    for (var i = 0; i < _songs.length; i++) {
      await db.upsertDownloaded(DownloadedTrack(
        id: 't$i',
        artist: _songs[i][0],
        title: _songs[i][1],
        path: '/tmp/t$i.mp3',
        bytes: 8 * _mb,
        addedAt: 100000 - i,
      ));
    }
  });
  final sync = SyncRepo(api, db);
  final offer = SyncOffer(DownloadsRepo(api, db, sync), freeSpace: () async => 48 * _gb);
  final app = ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      dbProvider.overrideWithValue(db),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(player ?? _QuietPlayer()),
      syncProvider.overrideWithValue(sync),
      syncOfferProvider.overrideWithValue(offer),
    ],
    child: const SoundFlowApp(),
  );
  return (app, offer, db);
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    await _loadFonts();
  });
  tearDown(() => Notice.hide());

  Future<void> shot(WidgetTester t, String name) =>
      expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));

  void phone(WidgetTester t) {
    t.view.physicalSize = const Size(800, 1720);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
  }

  testWidgets('карточка «12 новых песен» + плашка-предложение при заходе', (t) async {
    phone(t);
    final (app, offer, db) = await _app(t);
    await t.pumpWidget(app);
    await t.pumpAndSettle();
    await t.tap(find.text('Моя музыка'));
    await t.pumpAndSettle();
    offer.debugSet(
      preview: const PlanPreview(addCount: 12, addBytes: 85 * _mb),
      freeBytes: 48 * _gb,
    );
    Notice.show(
      offer.addTitle,
      subtitle: offer.addSubtitle,
      duration: const Duration(seconds: 12),
      actions: [NoticeAction('Скачать', () {}), NoticeAction('Не сейчас', () {}, primary: false)],
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    await shot(t, 'sync_1_offer');
    await db.close();
  });

  testWidgets('места не хватает + убрали на компьютере', (t) async {
    phone(t);
    final (app, offer, db) = await _app(t);
    await t.pumpWidget(app);
    await t.pumpAndSettle();
    await t.tap(find.text('Моя музыка'));
    await t.pumpAndSettle();
    offer.debugSet(
      preview: const PlanPreview(addCount: 1240, addBytes: 10520 * _mb, removeCount: 1474),
      freeBytes: (6.1 * _gb).round(),
    );
    await t.pumpAndSettle();
    await shot(t, 'sync_2_low_space');
    await db.close();
  });

  testWidgets('идёт скачивание: 3 из 12, «Стоп»', (t) async {
    phone(t);
    final (app, offer, db) = await _app(t);
    await t.pumpWidget(app);
    await t.pumpAndSettle();
    await t.tap(find.text('Моя музыка'));
    await t.pumpAndSettle();
    offer.debugSet(
      preview: const PlanPreview(addCount: 12, addBytes: 85 * _mb),
      running: true,
      done: 3,
      total: 12,
      current: 'Кино — Группа крови',
    );
    await t.pump(const Duration(milliseconds: 100));
    await shot(t, 'sync_3_running');
    offer.debugSet(running: false);
    await t.pumpAndSettle();
    await db.close();
  });

  testWidgets('удалил в плеере — плашка «Убрал с телефона»', (t) async {
    phone(t);
    final player = _QuietPlayer()
      ..now.value = const NowPlaying(id: 't_demo', title: 'Спокойная ночь', artist: 'Кино');
    player.duration.value = const Duration(minutes: 4, seconds: 33);
    player.position.value = const Duration(minutes: 1, seconds: 12);
    final (app, _, db) = await _app(t, player: player);
    await t.pumpWidget(app);
    await t.pump(const Duration(milliseconds: 600));
    Notice.show('Убрал с телефона', subtitle: 'Кино — Группа крови', kind: NoticeKind.removed);
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    await shot(t, 'sync_4_removed');
    await db.close();
  });

  testWidgets('Профиль: строка «Музыка с компьютера» + плашка «Готово»', (t) async {
    phone(t);
    final (app, offer, db) = await _app(t);
    await t.pumpWidget(app);
    await t.pumpAndSettle();
    await t.tap(find.text('Профиль'));
    await t.pumpAndSettle();
    offer.debugSet(checkedAt: DateTime(2026, 9, 20, 10, 2));
    Notice.show('Готово', subtitle: 'Скачано 12', kind: NoticeKind.done);
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    await shot(t, 'sync_5_profile_done');
    await db.close();
  });

  testWidgets('нет связи: плашка с кнопкой «Проверить связь»', (t) async {
    phone(t);
    final (app, _, db) = await _app(t);
    await t.pumpWidget(app);
    await t.pumpAndSettle();
    await t.tap(find.text('Профиль'));
    await t.pumpAndSettle();
    Notice.show(
      'Сервер не ответил',
      subtitle: 'Открой окно SoundFlow на компьютере — телефон отвечает только пока оно открыто.',
      kind: NoticeKind.error,
      duration: const Duration(seconds: 7),
      actions: [NoticeAction('Проверить связь', () {})],
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    await shot(t, 'sync_6_error');
    await db.close();
  });
}
