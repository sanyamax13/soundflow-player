// Рендер новых экранов для показа Alex (не проверка логики):
//   1. «Моя музыка» — склеенные исполнители + секция «Имя не читается»
//   2. одна папка исполнителя — песни с полным написанием совместок
// Запуск: flutter test --update-goldens test/mymusic_folders_shots.dart
// Картинки: test/goldens/folders_*.png

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
import 'package:soundflow/features/my_music/my_music_screen.dart';
import 'package:soundflow/features/player/player_controller.dart';

class _FakeApi extends Api {
  _FakeApi();
  @override
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async => const [];
}

// Реальные написания из library Alex (сервер, 07.09.2026).
const _seed = <(String artist, String title)>[
  ('9 грамм', 'Легенды'),
  ('9 Грамм', 'Косяки'),
  ('9 Грамм feat. Miyagi, Эндшпиль', 'Рапапам'),
  ('9 грамм, Artizio', 'Дым'),
  ('9 грамм, Lo Ali', 'Париж'),
  ('DAVID GUETTA', 'Titanium'),
  ('David Guetta', 'Memories'),
  ('DAVID GUETTA, BENNY BENASSI', 'Satisfaction'),
  ('David Guetta, Sia', 'Flames'),
  ('Баста', 'Сансара'),
  ('БАСТА, ЮНА', 'Любовь и голуби'),
  ('Баста feat. HammAli & Navai', 'Судьба'),
  ('The Weeknd', 'Blinding Lights'),
  ('THE WEEKND', 'Save Your Tears'),
  ('ABBA', 'Dancing Queen'),
  ('Kalush Orchestra', 'Stefania'),
];

// Битые имена — как на скрине Alex.
const _broken = <(String id, String artist, String title)>[
  ('t_cde2425083e92797', '???? ????????, ??????? ???????', '??????'),
  ('bad2', '?????, ??????', 'Piano Sonata'),
];

Future<Db> _db() async {
  final db = await Db.open(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
  const brK = [320, 256, 192, 320, 128, 320];
  const fmt = ['MP3', 'MP3', 'MP3', 'FLAC', 'M4A', 'MP3'];
  for (var i = 0; i < _seed.length; i++) {
    final (artist, title) = _seed[i];
    await db.upsertDownloaded(DownloadedTrack(
      id: 'id$i',
      title: title,
      artist: artist,
      path: '/tmp/id$i.mp3',
      bytes: (7 + i % 6) * 1024 * 1024,
      addedAt: 1000 - i,
      favorite: i % 6 == 0,
      bitrateKbps: brK[i % brK.length],
      format: fmt[i % fmt.length],
      durationSec: 150 + (i * 23) % 190,
    ));
  }
  for (final (id, artist, title) in _broken) {
    await db.upsertDownloaded(DownloadedTrack(
      id: id,
      title: title,
      artist: artist,
      path: '/tmp/$id.mp3',
      bytes: 7 * 1024 * 1024,
      addedAt: 1,
    ));
  }
  return db;
}

Future<Widget> _wrap(Db db, Widget home) async {
  final api = _FakeApi();
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
      home: home,
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
  });

  testWidgets('склейка исполнителей + «Имя не читается»',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 880));
    final db = await _db();

    await tester.pumpWidget(await _wrap(db, const MyMusicScreen()));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/folders_1_artists.png'));

    await tester.tap(find.text('9 грамм'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/folders_2_songs.png'));

  });
}
