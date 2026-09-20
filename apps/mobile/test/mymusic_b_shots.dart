// Рендер НАСТОЯЩЕГО экрана «Моя музыка» (вид «Б», 20.09.2026) в PNG на настоящих
// песнях с ПК Alex — для показа перед сборкой. Не проверка логики. Запуск:
//   SHOT_TRACKS=<путь к json [[id, artist, title], ...]> \
//   flutter test --update-goldens test/mymusic_b_shots.dart
// Картинки: test/goldens/mymusic_b_*.png
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
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/main.dart';

class _FakeApi extends Api {
  _FakeApi();
  @override
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async => const [];
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
      await (FontLoader('MaterialIcons')
            ..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer))))
          .load();
      break;
    }
  }
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    await _loadFonts();
  });

  testWidgets('вид «Б»: список, прыжок по букве, поиск, папка исполнителя', (tester) async {
    final path = Platform.environment['SHOT_TRACKS'];
    if (path == null) fail('задай SHOT_TRACKS=путь к json с песнями');
    final rows = (jsonDecode(File(path).readAsStringSync()) as List)
        .map((r) => (r as List).cast<String>())
        .toList();

    tester.view.physicalSize = const Size(800, 1720);
    tester.view.devicePixelRatio = 2;
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
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        dbProvider.overrideWithValue(db),
        downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
        playerProvider.overrideWithValue(_QuietPlayer()),
        syncProvider.overrideWithValue(sync),
      ],
      child: const SoundFlowApp(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Моя музыка'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 30));

    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/mymusic_b_1_list.png'));

    // Палец ведёт по полоске букв примерно до середины — список прыгает.
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.dragFrom(Offset(view.width - 12, 300), const Offset(0, 130));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/mymusic_b_2_jump.png'));

    await tester.enterText(find.byType(TextField), 'depeche');
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/mymusic_b_3_search.png'));

    await tester.tap(find.text('Depeche Mode').first);
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/mymusic_b_4_artist.png'));

    await db.close();
  }, timeout: const Timeout(Duration(minutes: 6)));
}
