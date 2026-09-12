// Рендер НАСТОЯЩЕГО экрана плеера (PlayerView, вариант 4.2) в PNG — чтобы
// Alex увидел его глазами до сборки APK. Не проверка логики. Запуск:
//   flutter test --update-goldens test/player_real_shot.dart
// Картинки: test/goldens/player_real.png, player_real_help.png
//
// Виджеты и вёрстка — настоящие; проигрыватель — заглушка (аудиоплагинов в
// тесте нет), обложка без файла → показывается запасной значок.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/core/theme.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/cover_art.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/features/player/player_view.dart';

Future<Widget> _app() async {
  final api = Api();
  final db = await Db.open(
      path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  final sync = SyncRepo(api, db);
  final player = PlayerController()
    ..now.value = const NowPlaying(
        id: 't_demo', title: 'Спокойная ночь', artist: 'Кино');
  player.duration.value = const Duration(minutes: 4, seconds: 33);
  player.position.value = const Duration(minutes: 1, seconds: 12);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(player),
      syncProvider.overrideWithValue(sync),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: Scaffold(
        backgroundColor: Afisha.bg,
        body: PlayerView(onDismiss: () {}),
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final f = File('assets/fonts/Inter-$w.ttf');
      if (f.existsSync()) {
        await (FontLoader('Inter')
              ..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer))))
            .load();
      }
    }
    for (final p in [
      r'E:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
      r'E:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    ]) {
      final f = File(p);
      if (f.existsSync()) {
        await (FontLoader('MaterialIcons')
              ..addFont(
                  Future.value(ByteData.view(f.readAsBytesSync().buffer))))
            .load();
        break;
      }
    }
  });

  testWidgets('плеер 4.2 — обычный вид', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(await _app());
    await t.pump(const Duration(milliseconds: 300));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/player_real.png'));
  });

  testWidgets('плеер 4.2 — инструкция', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(await _app());
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byIcon(Icons.help_outline));
    await t.pump(const Duration(milliseconds: 200));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/player_real_help.png'));
  });

  testWidgets('плеер 4.2 — меню действий (долгое нажатие)', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(await _app());
    await t.pump(const Duration(milliseconds: 300));
    await t.longPress(find.byType(CoverArt).first);
    await t.pump(const Duration(milliseconds: 400));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/player_real_menu.png'));
  });
}
