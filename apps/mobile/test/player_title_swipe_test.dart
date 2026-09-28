// Смахивание строки «название + исполнитель» (Alex, голосовое 28.09.2026): влево — следующая,
// вправо — предыдущая, короткое движение — ничего. И шторка очереди тянется без ошибок.

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
import 'package:soundflow/features/player/seek_skin.dart';

Future<Widget> _app(_FakePlayer player, {Future<void> Function(Db db)? seed}) async {
  final api = Api();
  final db = await Db.open(
      path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  if (seed != null) await seed(db);
  final sync = SyncRepo(api, db);
  player
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

class _FakePlayer extends PlayerController {
  int nexts = 0, prevs = 0;
  @override
  Future<void> next({bool reportSkip = true}) async => nexts++;
  @override
  Future<void> prev() async => prevs++;
}

/// Кадр за кадром: анимация отъезда строки идёт по кадрам, один большой pump её не прокручивает.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('строка названия: влево — следующая, вправо — предыдущая, чуть-чуть — ничего', (t) async {
    await t.binding.setSurfaceSize(const Size(412, 915));
    final p = _FakePlayer();
    await t.pumpWidget(await _app(p));
    await t.pump(const Duration(milliseconds: 300));
    final title = find.byKey(const ValueKey('player_title_swipe'));
    await t.drag(title, const Offset(-150, 0));
    await settle(t);
    expect(p.nexts, 1);
    await t.drag(title, const Offset(150, 0));
    await settle(t);
    expect(p.prevs, 1);
    await t.drag(title, const Offset(-20, 0));
    await settle(t);
    expect(p.nexts, 1);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('вид «Листание»: обложка листает, есть урна и сердечко; «Оценка» — без них', (t) async {
    await t.binding.setSurfaceSize(const Size(412, 915));
    final p = _FakePlayer();
    await t.pumpWidget(await _app(p));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('player_fav')), findsNothing);
    expect(find.byKey(const ValueKey('player_delete')), findsNothing);
    seekSkin.value = SeekSkin.glass;
    addTearDown(() => seekSkin.value = SeekSkin.equalizer);
    await t.pump();
    expect(find.byKey(const ValueKey('player_fav')), findsOneWidget);
    expect(find.byKey(const ValueKey('player_delete')), findsOneWidget);
    final cover = find.byType(Hero).first;
    await t.drag(cover, const Offset(-150, 0));
    await settle(t);
    expect(p.nexts, 1);
    await t.drag(cover, const Offset(150, 0));
    await settle(t);
    expect(p.prevs, 1);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}
