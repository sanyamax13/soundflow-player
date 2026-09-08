// Разовый рендер: вкладка «Избранное» в «Моей музыке» после правки —
// исполнитель с 1 песней показывается строкой песни, с 2+ — папкой.
// Для показа Alex. flutter test --update-goldens test/mymusic_fav_shot.dart

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
import 'package:soundflow/features/my_music/my_music_screen.dart';
import 'package:soundflow/features/player/player_controller.dart';

class _FakeApi extends Api {
  @override
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async => const [];
}

// как на скрине Alex — куча избранного по одной песне + один многопесенный.
const _fav = <(String artist, String title)>[
  ('9 Грамм', 'Дэнс'),
  ('ABBA', 'Summer Night City'),
  ('Aziza Qobilova', 'Come Along'),
  ('Burito', 'К небу протянуты руки'),
  ('Delaitech', 'Vibe'),
  ('DJ Snake', 'Taki Taki'),
  ('DOMBAY & ПТАХА', 'Весна'),
  ('МИТЯ ФОМИН & ТАЙПАН', 'Бумажный самолёт'),
  ('Земфира', 'Сигареты'),
  ('Земфира', 'Искала'), // у этого артиста 2 — останется папкой
];

Future<Db> _db() async {
  final db = await Db.open(
      path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  for (var i = 0; i < _fav.length; i++) {
    final (artist, title) = _fav[i];
    await db.upsertDownloaded(DownloadedTrack(
      id: 'f$i',
      title: title,
      artist: artist,
      path: '/tmp/f$i.mp3',
      bytes: (6 + i % 5) * 1024 * 1024,
      addedAt: 1000 - i,
      favorite: true,
      bitrateKbps: 320,
      format: 'MP3',
      durationSec: 180 + i * 7,
    ));
  }
  return db;
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
  });

  testWidgets('Избранное — 1 песня строкой, 2+ папкой', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 880));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = await _db();
    final api = _FakeApi();
    final sync = SyncRepo(api, db);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
        playerProvider.overrideWithValue(PlayerController()),
        syncProvider.overrideWithValue(sync),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: Afisha.theme(),
        home: const MyMusicScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Избранное'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/mymusic_fav.png'));
  });
}
