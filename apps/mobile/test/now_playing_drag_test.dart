// «Живое» закрытие полного плеера (27.09.2026): тянешь за шапку вниз — едет за пальцем;
// дальше 35% высоты — закрывается, меньше — возвращается.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
import 'package:soundflow/features/player/now_playing_screen.dart';
import 'package:soundflow/features/player/player_controller.dart';

Future<void> _open(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(400, 860));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final api = Api();
  final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  addTearDown(db.close);
  final sync = SyncRepo(api, db);
  final player = PlayerController()..now.value = const NowPlaying(id: 't', title: 'Песня', artist: 'Кто-то');
  await t.pumpWidget(ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      dbProvider.overrideWithValue(db),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(player),
      syncProvider.overrideWithValue(sync),
      syncOfferProvider.overrideWithValue(SyncOffer(DownloadsRepo(api, db, sync))),
    ],
    child: MaterialApp(
      theme: Afisha.theme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(NowPlayingScreen.route()),
              child: const Text('открыть'),
            ),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text('открыть'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
  expect(find.byType(NowPlayingScreen), findsOneWidget);
}

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('потянул за шапку на 40% — плеер закрылся', (t) async {
    await _open(t);
    final g = await t.startGesture(t.getCenter(find.byIcon(SolarIconsOutline.altArrowDown)) + const Offset(120, 0));
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(0, 17.2)); // всего 344 = 40% от 860, медленно
      await t.pump(const Duration(milliseconds: 50));
    }
    await g.up();
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(NowPlayingScreen), findsNothing);
  });

  testWidgets('потянул на 15% и отпустил — плеер вернулся на место', (t) async {
    await _open(t);
    final g = await t.startGesture(t.getCenter(find.byIcon(SolarIconsOutline.altArrowDown)) + const Offset(120, 0));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 12.9)); // 129 = 15%
      await t.pump(const Duration(milliseconds: 60));
    }
    await g.up();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(NowPlayingScreen), findsOneWidget);
    // Вернулся на место: шапка снова у самого верха.
    expect(t.getTopLeft(find.byIcon(SolarIconsOutline.altArrowDown)).dy, lessThan(80));
  });
}
