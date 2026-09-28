// Шторка «Настроение» со значками Solar (28.09.2026). Рендер НАСТОЯЩЕГО экрана плеера (PlayerView, вариант 4.2) в PNG — чтобы
// Alex увидел его глазами до сборки APK. Не проверка логики. Запуск:
//   flutter test --update-goldens test/player_real_shot.dart
// Картинка: test/goldens/player_real.png
//
// Виджеты и вёрстка — настоящие; проигрыватель — заглушка (аудиоплагинов в
// тесте нет), обложка без файла → показывается запасной значок.
//
// Второй тест («инструкция») убран 25.09.2026 вместе с кнопкой-вопросиком
// (Alex TG: «удали её») — раньше он тыкал в эту кнопку, чтобы открыть
// _HelpOverlay. Сама подсказка осталась (показывается один раз при первом
// запуске, path_provider), но в виджет-тесте этот путь молча не срабатывает
// (нет платформенного плагина, try/catch внутри _maybeShowHelpFirstRun это
// проглатывает) — без убранной кнопки честного способа открыть её из теста
// не осталось, свою скриншот-проверку не оставляем ради проверки ради неё.

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

Future<Widget> _app({Future<void> Function(Db db)? seed}) async {
  final api = Api();
  final db = await Db.open(
      path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  if (seed != null) await seed(db);
  final sync = SyncRepo(api, db);
  final player = PlayerController()
    ..now.value = const NowPlaying(
        id: 't_demo', title: 'Спокойная ночь', artist: 'Кино');
  player.duration.value = const Duration(minutes: 4, seconds: 33);
  player.position.value = const Duration(minutes: 1, seconds: 12);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      dbProvider.overrideWithValue(db),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(player),
      syncProvider.overrideWithValue(sync),
      syncOfferProvider.overrideWithValue(SyncOffer(DownloadsRepo(api, db, sync))),
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
    // Значки Solar (шрифт пакета solar_icons) — иначе на картинке вместо них квадраты.
    for (final w in ['Bold', 'Outline']) {
      final f = File('${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/solar_icons-0.1.0/fonts/SolarIcons$w.ttf');
      if (f.existsSync()) {
        await (FontLoader('packages/solar_icons/SolarIcons$w')
              ..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer))))
            .load();
      }
    }
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final f = File('assets/fonts/Inter-$w.ttf');
      if (f.existsSync()) {
        await (FontLoader('Inter')
              ..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer))))
            .load();
      }
    }
    final grotesk = File('assets/fonts/SpaceGrotesk-Regular.ttf');
    if (grotesk.existsSync()) {
      await (FontLoader('SpaceGrotesk')
            ..addFont(Future.value(ByteData.view(grotesk.readAsBytesSync().buffer))))
          .load();
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
    // Весь этот экран — CupertinoIcons (не MaterialIcons), поэтому без
    // отдельной загрузки их шрифта все значки на скрине были квадратиками.
    // Family должна совпадать с тем, во что Flutter резолвит IconData с
    // package: 'cupertino_icons' — 'packages/cupertino_icons/CupertinoIcons'.
    final cupertino = File(
        '/home/alex/.pub-cache/hosted/pub.dev/cupertino_icons-1.0.9/assets/CupertinoIcons.ttf');
    if (cupertino.existsSync()) {
      await (FontLoader('packages/cupertino_icons/CupertinoIcons')
            ..addFont(Future.value(
                ByteData.view(cupertino.readAsBytesSync().buffer))))
          .load();
    }
  });

  testWidgets('шторка настроения — значки Solar', (t) async {
    await t.binding.setSurfaceSize(const Size(412, 915));
    await t.pumpWidget(await _app(seed: (db) async {
      for (var i = 0; i < 3; i++) {
        for (final m in ['happy', 'energetic', 'tender', 'sad', 'aggressive', 'dance']) {
          await db.upsertDownloaded(DownloadedTrack(
              id: 't_${m}_$i', title: 'Песня', artist: 'А', path: '/x', bytes: 1, addedAt: 0, mood: m));
        }
      }
    }));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const ValueKey('mode_mood')));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 60));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/picker_mood_solar.png'));
  });
}
