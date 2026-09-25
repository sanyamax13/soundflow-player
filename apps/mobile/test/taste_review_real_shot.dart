// Рендер НАСТОЯЩЕГО экрана «Разбор коллекции» (TasteReviewScreen) в PNG —
// для аудита дизайна всего плеера у внешнего ИИ (Alex TG 25.09.2026). Не
// проверка логики. Имя файла без суффикса _test → обычный `flutter test`
// его не подхватывает. Запуск:
//   flutter test --update-goldens test/taste_review_real_shot.dart
// Картинка: test/goldens/taste_review_screen.png

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
        {'id': 't4', 'artist': 'The Weeknd', 'title': 'Blinding Lights', 'album': 'After Hours', 'score': 0.77},
        {'id': 't5', 'artist': 'Unknown Artist', 'title': 'Random Track', 'album': '', 'score': 0.61},
      ];
}

Future<Widget> _app() async {
  final api = _FakeApi();
  final db = await Db.open(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
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

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    final inter = File('assets/fonts/Inter-Regular.ttf').readAsBytesSync();
    await (FontLoader('Inter')
          ..addFont(Future.value(ByteData.view(inter.buffer))))
        .load();
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
    final cupertino = File(
        r'C:\Users\brain\AppData\Local\Pub\Cache\hosted\pub.dev\cupertino_icons-1.0.9\assets\CupertinoIcons.ttf');
    if (cupertino.existsSync()) {
      await (FontLoader('packages/cupertino_icons/CupertinoIcons')
            ..addFont(Future.value(ByteData.view(cupertino.readAsBytesSync().buffer))))
          .load();
    }
  });

  testWidgets('экран «Разбор коллекции»', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(await _app());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 600)); // догнать плавное появление строк (StaggeredEntry)
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/taste_review_screen.png'));
  });
}
