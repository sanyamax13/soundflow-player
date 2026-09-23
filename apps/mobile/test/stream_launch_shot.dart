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
import 'package:soundflow/data/sync_offer.dart';
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
      syncOfferProvider.overrideWithValue(SyncOffer(DownloadsRepo(api, db, sync))),
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
    // Экран «Поток» — почти все значки Cupertino (chevron, радио, сердце,
    // урна…). Без своего шрифта они рисуются пустыми квадратами — картинка
    // для Alex была бы нечестной. Путь берём из pubspec.lock (cupertino_icons).
    for (final p in [
      r'C:\Users\brain\AppData\Local\Pub\Cache\hosted\pub.dev\cupertino_icons-1.0.9\assets\CupertinoIcons.ttf',
    ]) {
      final f = File(p);
      if (f.existsSync()) {
        // TextStyle подставляет 'packages/<pkg>/<family>', когда у
        // IconData задан fontPackage — регистрировать надо под ЭТИМ именем,
        // иначе Flutter не найдёт шрифт и нарисует пустой квадрат.
        await (FontLoader('packages/cupertino_icons/CupertinoIcons')
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
