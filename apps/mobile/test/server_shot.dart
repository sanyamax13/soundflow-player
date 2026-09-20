// Рендер экрана «Сервер» (AdminScreen) в PNG — для показа Alex. Не проверка
// логики. Запуск:
//   flutter test --update-goldens test/server_shot.dart
// Картинка: test/goldens/server_screen.png
// Имя файла без суффикса _test → обычный `flutter test` его не подхватывает.

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
import 'package:soundflow/features/admin/admin_screen.dart';
import 'package:soundflow/features/player/player_controller.dart';

class _FakeApi extends Api {
  @override
  Future<Map<String, dynamic>> adminStatus() async => {
        'db': 'ok',
        'uptime_sec': 5 * 3600 + 12 * 60,
        'go_version': 'go1.25',
        'music_source': 'Яндекс + торренты',
        'migrations': ['0001', '0002', '0003', '0004', '0005'],
        'catalog': {
          'tracks': 8781,
          'track_files': 8774,
          'hidden_by_quality': 23,
        },
        'events': {
          'total': 1204,
          'by_kind': {'play': 980, 'like': 41, 'delete': 63, 'skip': 120},
        },
        'legacy': {'favorites': 25, 'blocked': 316},
        'devices': 1,
        'busy': const [],
        'disk': {
          'free_bytes': 549755813888,
          'total_bytes': 2000398934016,
          'music_bytes': 50465865728,
        },
        'report': {
          'days': 30,
          'added': 37,
          'removed': 12,
          'not_found': 4,
          'replaced': 3,
          'errors': 0,
          'freed_bytes': 428000000,
        },
      };
  @override
  Future<List<Map<String, dynamic>>> adminDevices() async => const [];
  @override
  Future<List<Map<String, dynamic>>> adminEvents({int limit = 20}) async => const [];
  @override
  Future<List<Map<String, dynamic>>> serverLog({int limit = 100}) async => const [
        {
          'kind': 'added',
          'artist': 'Земфира',
          'title': 'Искала',
          'detail': 'скачан по запросу из плеера',
          'at': '2026-09-07T09:12:00Z',
        },
        {
          'kind': 'replaced',
          'artist': 'Кино',
          'title': 'Спокойная ночь',
          'detail': 'заменил на версию получше',
          'at': '2026-09-06T21:40:00Z',
        },
        {
          'kind': 'removed',
          'artist': 'Radiohead',
          'title': 'Creep',
          'detail': 'убран из плеера',
          'at': '2026-09-06T18:03:00Z',
        },
        {
          'kind': 'not_found',
          'artist': 'Мумий Тролль',
          'title': 'Владивосток 2000',
          'detail': 'не нашёлся ни в одном источнике',
          'at': '2026-09-05T11:20:00Z',
        },
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
      home: const AdminScreen(),
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

  testWidgets('экран «Сервер» — синхронизация свёрнута сверху', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1560));
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();

    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/server_screen.png'));
  });
}
