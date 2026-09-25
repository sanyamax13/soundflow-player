// Демо свайп-интерфейса «Разбор коллекции» (Alex TG 25.09.2026, по разбору
// Gemini — «Tinder» вместо мелких кнопок). Реальный экран, палец тащит
// первую строку рукой теста (drag), кадры сняты на разных этапах — чтобы
// показать цветную подложку под пальцем. Не проверка логики. Запуск:
//   flutter test --update-goldens test/taste_review_swipe_demo_shot.dart
// Картинки: test/goldens/taste_swipe_{right,left}_frame_0..N.png

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
import 'package:soundflow/features/taste_review/taste_review_screen.dart';

class _FakeApi extends Api {
  @override
  Future<List<Map<String, dynamic>>> tasteReview({int? limit}) async => [
        {'id': 't1', 'artist': 'Flo Rida', 'title': 'Wild Ones ft. Sia', 'album': 'Wild Ones', 'score': 0.97},
        {'id': 't2', 'artist': 'Zemfira', 'title': 'Iskala', 'album': 'Vendetta', 'score': 0.91},
        {'id': 't3', 'artist': 'Kino', 'title': 'Gruppa krovi', 'album': '', 'score': 0.84},
      ];
}

Future<Widget> _app() async {
  final api = _FakeApi();
  final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  final sync = SyncRepo(api, db);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(PlayerController()),
      syncProvider.overrideWithValue(sync),
      syncOfferProvider.overrideWithValue(SyncOffer(DownloadsRepo(api, db, sync))),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Afisha.theme(),
      home: const TasteReviewScreen(),
    ),
  );
}

Future<void> _loadFonts() async {
  final inter = File('assets/fonts/Inter-Regular.ttf').readAsBytesSync();
  await (FontLoader('Inter')..addFont(Future.value(ByteData.view(inter.buffer)))).load();
  final cupertino = File(
      r'C:\Users\brain\AppData\Local\Pub\Cache\hosted\pub.dev\cupertino_icons-1.0.9\assets\CupertinoIcons.ttf');
  if (cupertino.existsSync()) {
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')
          ..addFont(Future.value(ByteData.view(cupertino.readAsBytesSync().buffer))))
        .load();
  }
}

Future<void> _dragFrames(WidgetTester tester, {required String prefix, required double maxDx}) async {
  await tester.binding.setSurfaceSize(const Size(390, 300));
  await tester.pumpWidget(await _app());
  await tester.pump(const Duration(milliseconds: 200));
  final row = find.text('Flo Rida — Wild Ones ft. Sia');
  final gesture = await tester.startGesture(tester.getCenter(row));
  const steps = 8;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveBy(Offset(maxDx / steps, 0));
    await tester.pump();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${prefix}_frame_$i.png'));
  }
  await gesture.up();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('свайп вправо — «Оставить» (зелёное)', (tester) async {
    await _dragFrames(tester, prefix: 'taste_swipe_right', maxDx: 170);
  });

  testWidgets('свайп влево — «Удалить» (красное)', (tester) async {
    await _dragFrames(tester, prefix: 'taste_swipe_left', maxDx: -170);
  });
}
