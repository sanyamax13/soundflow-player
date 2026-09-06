// Рендер НАСТОЯЩего экрана «Моя музыка» (вариант «Полка») в PNG — для показа
// Alex. Не проверка логики. Запуск:
//   flutter test --update-goldens test/mymusic_real_shots.dart
// Картинки: test/goldens/mymusic_polka_*.png
// Имя файла без суффикса _test → обычный `flutter test` его не подхватывает.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/main.dart';

class _FakeApi extends Api {
  _FakeApi();
  @override
  Future<List<Map<String, dynamic>>> tracks() async => const [];
}

const _seed = <(String artist, String title)>[
  ('ABBA', 'Dancing Queen'),
  ('ABBA', 'Mamma Mia'),
  ('ABBA', 'SOS'),
  ('ABBA', 'The Winner Takes It All'),
  ('Dolly Parton', 'Jolene'),
  ('Dolly Parton', '9 to 5'),
  ('Dolly Parton', 'I Will Always Love You'),
  ('Fleetwood Mac', 'Dreams'),
  ('Fleetwood Mac', 'Go Your Own Way'),
  ('Fleetwood Mac', 'The Chain'),
  ('Kenny Rogers', 'The Gambler'),
  ('Kenny Rogers', 'Islands In The Stream'),
  ('Kenny Rogers', 'Through The Years'),
  ('Kenny Rogers', 'Coward Of The County'),
  ('Kenny Rogers', 'Buy Me A Rose'),
  ('Queen', 'Bohemian Rhapsody'),
  ('Queen', 'Somebody To Love'),
  ('Queen', "Don't Stop Me Now"),
  ('Sting', 'Fields Of Gold'),
  ('Sting', 'Shape Of My Heart'),
];

Future<Widget> _app() async {
  final api = _FakeApi();
  final db = await Db.open(
    path: inMemoryDatabasePath,
    factory: databaseFactoryFfiNoIsolate,
  );
  for (var i = 0; i < _seed.length; i++) {
    final (artist, title) = _seed[i];
    await db.upsertDownloaded(DownloadedTrack(
      id: 'id$i',
      title: title,
      artist: artist,
      path: '/tmp/id$i.mp3',
      bytes: (7 + i % 6) * 1024 * 1024,
      addedAt: 1000 - i,
      favorite: i % 5 == 0,
    ));
  }
  final sync = SyncRepo(api, db);
  return SoundFlowApp(
    api: api,
    downloads: DownloadsRepo(api, db, sync),
    player: PlayerController(),
    sync: sync,
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

  testWidgets('полка: список исполнителей + песни одного', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 860));
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Моя музыка').first);
    await tester.pumpAndSettle();

    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/mymusic_polka_1_artists.png'));

    await tester.tap(find.text('Kenny Rogers'));
    await tester.pumpAndSettle();

    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/mymusic_polka_2_songs.png'));
  });
}
