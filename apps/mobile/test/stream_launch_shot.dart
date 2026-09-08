// Разовый рендер: как выглядит вкладка «Поток» СРАЗУ при запуске после
// правки (полный плеер на паузе, а не голая кнопка play). Для показа Alex.
//   flutter test --update-goldens test/stream_launch_shot.dart
// Картинка: test/goldens/stream_launch.png

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
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/features/player/player_view.dart';

Future<Widget> _app() async {
  final api = Api();
  final db = await Db.open(
      path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  final sync = SyncRepo(api, db);
  // Очередь заряжена на паузе — как делает StreamScreen при открытии вкладки.
  final player = PlayerController()
    ..now.value = const NowPlaying(
        id: 't_demo', title: "Drop A Gem On 'em", artist: 'MOBB DEEP');
  player.duration.value = const Duration(minutes: 4, seconds: 2);
  player.position.value = Duration.zero;
  player.playing.value = false;
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
      home: Scaffold(backgroundColor: Afisha.bg, body: const PlayerView()),
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

  testWidgets('Поток — вид сразу при запуске', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(await _app());
    await t.pump(const Duration(milliseconds: 300));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/stream_launch.png'));
  });
}
