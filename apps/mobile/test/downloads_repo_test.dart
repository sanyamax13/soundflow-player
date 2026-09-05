import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';

/// Обложку по сети не тянем по-настоящему — пишем маленький фейковый файл,
/// чтобы проверить, что DownloadsRepo сохраняет путь в базе (05.09.2026,
/// docachat oblozhki uzhe skachannym).
class _FakeApi extends Api {
  _FakeApi();
  final List<String> requestedUrls = [];
  bool fail = false;

  @override
  Future<void> downloadCover(String url, String toPath) async {
    requestedUrls.add(url);
    if (fail) throw Exception('нет обложки');
    await File(toPath).writeAsBytes([1, 2, 3]);
  }
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('soundflow_covers_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Db> freshDb() =>
      Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

  test('backfillCovers докачивает обложку и сохраняет путь в базе', () async {
    final db = await freshDb();
    final api = _FakeApi();
    final downloads = DownloadsRepo(api, db, SyncRepo(api, db));

    await db.upsertDownloaded(DownloadedTrack(
      id: 't1', title: 'Песня', artist: 'Кто-то', path: '/tmp/t1', bytes: 10, addedAt: 1,
    ));

    await downloads.backfillCovers();

    final row = await db.downloadedById('t1');
    expect(row!.coverPath, isNotNull);
    expect(File(row.coverPath!).existsSync(), isTrue);
    expect(api.requestedUrls, hasLength(1));
    expect(api.requestedUrls.single, contains('/v1/cover/t1'));

    await db.close();
  });

  test('уже скачанную обложку второй раз не трогает', () async {
    final db = await freshDb();
    final api = _FakeApi();
    final downloads = DownloadsRepo(api, db, SyncRepo(api, db));

    final existing = File('${tmp.path}/already.jpg')..writeAsBytesSync([9]);
    await db.upsertDownloaded(DownloadedTrack(
      id: 't1', title: 'Песня', artist: 'Кто-то', path: '/tmp/t1', bytes: 10, addedAt: 1,
      coverPath: existing.path,
    ));

    await downloads.backfillCovers();

    expect(api.requestedUrls, isEmpty);

    await db.close();
  });

  test('не нашлась обложка — трек остаётся без неё, не падает', () async {
    final db = await freshDb();
    final api = _FakeApi()..fail = true;
    final downloads = DownloadsRepo(api, db, SyncRepo(api, db));

    await db.upsertDownloaded(DownloadedTrack(
      id: 't1', title: 'Песня', artist: 'Кто-то', path: '/tmp/t1', bytes: 10, addedAt: 1,
    ));

    await downloads.backfillCovers();

    final row = await db.downloadedById('t1');
    expect(row!.coverPath, isNull);

    await db.close();
  });
}
