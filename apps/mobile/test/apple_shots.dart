// Рендер НАСТОЯЩИХ экранов телефона в PNG на настоящих песнях с ПК Alex — для показа оформления «как у Apple»
// (Alex TG 20345, 21.09.2026) ДО сборки APK. Не проверка логики. Запуск:
//   SHOT_TAG=after SHOT_TRACKS=<путь к json [[id, artist, title], ...]> \
//   flutter test --update-goldens test/apple_shots.dart
// Картинки: test/goldens/apple_<метка>_*.png
// Имя файла без суффикса _test → обычный `flutter test` его не подхватывает.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  @override
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async => const [];

  @override
  Future<Map<String, dynamic>> adminStatus() async => {
        'db': 'ok',
        'uptime_sec': 5 * 3600 + 12 * 60,
        'go_version': 'go1.25',
        'music_source': 'Яндекс + торренты',
        'migrations': ['0001', '0002', '0003'],
        'catalog': {'tracks': 1552, 'track_files': 1556, 'hidden_by_quality': 23},
        'events': {
          'total': 1204,
          'by_kind': {'play': 980, 'like': 41, 'delete': 63, 'skip': 120},
        },
        'legacy': {'favorites': 25, 'blocked': 316},
        'devices': 1,
        'busy': const [],
        'disk': {'free_bytes': 549755813888, 'total_bytes': 2000398934016, 'music_bytes': 50465865728},
        'report': {'days': 30, 'added': 37, 'removed': 12, 'not_found': 4, 'replaced': 3, 'errors': 0, 'freed_bytes': 428000000},
      };

  @override
  Future<List<Map<String, dynamic>>> adminDevices() async => const [];
  @override
  Future<List<Map<String, dynamic>>> adminEvents({int limit = 20}) async => const [];
  @override
  Future<List<Map<String, dynamic>>> serverLog({int limit = 100}) async => const [];
}

/// Плеер, который не трогает аудио-плагин (его в тестах нет).
class _QuietPlayer extends PlayerController {
  @override
  Future<void> playQueue(
    List<NowPlaying> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    bool loop = true,
    bool autoplay = true,
    Duration initialPosition = Duration.zero,
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
  final cup = Directory(r'C:\Users\brain\AppData\Local\Pub\Cache\hosted\pub.dev')
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.contains('cupertino_icons-'))
      .map((d) => File('${d.path}/assets/CupertinoIcons.ttf'))
      .where((f) => f.existsSync())
      .toList();
  if (cup.isNotEmpty) {
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')
          ..addFont(Future.value(ByteData.view(cup.last.readAsBytesSync().buffer))))
        .load();
  }
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    await _loadFonts();
  });

  testWidgets('оформление: Моя музыка, папка, Профиль, Сервер, Поток', (tester) async {
    final tag = Platform.environment['SHOT_TAG'] ?? 'after';
    final path = Platform.environment['SHOT_TRACKS'];
    if (path == null) fail('задай SHOT_TRACKS=путь к json с песнями');
    final rows = (jsonDecode(File(path).readAsStringSync()) as List).map((r) => (r as List).cast<String>()).toList();

    tester.view.physicalSize = const Size(1170, 2532); // 390×844 точек, как iPhone 14
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final api = _FakeApi();
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    await tester.runAsync(() async {
      for (var i = 0; i < rows.length; i++) {
        await db.upsertDownloaded(DownloadedTrack(
          id: rows[i][0],
          artist: rows[i][1],
          title: rows[i][2],
          path: '/tmp/${rows[i][0]}.mp3',
          bytes: 8 * 1024 * 1024,
          addedAt: 100000 - i,
        ));
      }
    });
    final sync = SyncRepo(api, db);
    final player = _QuietPlayer();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        dbProvider.overrideWithValue(db),
        downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
        playerProvider.overrideWithValue(player),
        syncProvider.overrideWithValue(sync),
        syncOfferProvider.overrideWithValue(SyncOffer(DownloadsRepo(api, db, sync))),
      ],
      child: const SoundFlowApp(),
    ));
    await tester.pumpAndSettle();

    // Поток (первая вкладка): играет песня
    player.now.value = NowPlaying(id: rows[3][0], title: rows[3][2], artist: rows[3][1]);
    player.duration.value = const Duration(minutes: 4, seconds: 33);
    player.position.value = const Duration(minutes: 1, seconds: 12);
    // у плеера бесконечный перелив фона — pumpAndSettle не дождётся, крутим кадры руками
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/apple_${tag}_5_stream.png'));

    await tester.tap(find.text('Моя музыка'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/apple_${tag}_1_mymusic.png'));

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/apple_${tag}_3_profile.png'));

    await tester.tap(find.text('Сервер'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/apple_${tag}_4_server.png'));

    // «Показать опасное» → кнопка → окно подтверждения (только «после»: до переделки этих кадров не снимали)
    if (tag != 'before') {
      await tester.tap(find.text('Показать опасное'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/apple_${tag}_7_danger.png'));
      await tester.tap(find.text('Полный сброс'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/apple_${tag}_8_dialog.png'));
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
      await tester.pageBack();
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/apple_${tag}_6_settings.png'));
    }
  });
}
