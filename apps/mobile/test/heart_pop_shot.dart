// Разовый рендер: куда прилетает сердечко при лайке — раньше в центр
// экрана, теперь на кнопку лайка внизу (Опус-ревью «Поток» 23.09.2026,
// пункт 3). Ловим кадр посреди анимации (~230 мс из 720).
//   flutter test --update-goldens test/heart_pop_shot.dart
// Картинка: test/goldens/heart_pop.png

import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:solar_icons/solar_icons.dart';
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
  final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  final sync = SyncRepo(api, db);
  final player = PlayerController()
    ..now.value = const NowPlaying(id: 't_demo', title: "Drop A Gem On 'em", artist: 'MOBB DEEP');
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
        await (FontLoader('Inter')..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)))).load();
      }
    }
    for (final p in [
      r'C:\Users\brain\AppData\Local\Pub\Cache\hosted\pub.dev\cupertino_icons-1.0.9\assets\CupertinoIcons.ttf',
    ]) {
      final f = File(p);
      if (f.existsSync()) {
        await (FontLoader('packages/cupertino_icons/CupertinoIcons')
              ..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer))))
            .load();
        break;
      }
    }
  });

  testWidgets('сердечко посреди анимации лайка', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 860));
    await t.pumpWidget(await _app());
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    await t.tap(find.byIcon(SolarIconsOutline.heart));
    await t.pump();
    await t.pump(const Duration(milliseconds: 230));

    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/heart_pop.png'));
  });
}
