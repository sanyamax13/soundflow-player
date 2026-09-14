import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';

/// Кнопка «Стоп» на «Докачать ещё» (Опус-ревью телефона 14.09.2026, пункт 7)
/// — раньше начатую порцию было нельзя прервать.
class _FakeApi extends Api {
  _FakeApi(this._tracks);
  final List<Map<String, dynamic>> _tracks;

  @override
  Future<({List<Map<String, dynamic>> tracks, int totalBytes})> nextLibraryBatch({
    List<String> excludeIds = const [],
    int budgetBytes = 0,
  }) async =>
      (tracks: _tracks, totalBytes: 0);

  @override
  Future<void> downloadTrack(String id, String toPath) async {
    await File(toPath).writeAsBytes([1, 2, 3]);
  }
}

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('soundflow_cancel_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('отмена посреди порции — докачанное остаётся, дальше не идёт', () async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final tracks = [
      for (var i = 0; i < 5; i++) {'id': 't$i', 'title': 'Песня $i', 'artist': 'X'},
    ];
    final api = _FakeApi(tracks);
    final downloads = DownloadsRepo(api, db, SyncRepo(api, db));
    final token = DownloadCancelToken();

    final r = await downloads.downloadMore(
      cancelToken: token,
      onProgress: (done, total, title) {
        // Отмена проверяется в НАЧАЛЕ каждого следующего трека — тот, что
        // уже в процессе (для которого как раз пришёл этот onProgress),
        // докачивается до конца; следующий уже не начинается.
        if (done == 1) token.cancel();
      },
    );

    expect(r.downloaded, 2);
    expect((await db.allDownloaded()).length, 2);

    await db.close();
  });

  test('без отмены — качает всё как раньше', () async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final tracks = [
      for (var i = 0; i < 3; i++) {'id': 't$i', 'title': 'Песня $i', 'artist': 'X'},
    ];
    final api = _FakeApi(tracks);
    final downloads = DownloadsRepo(api, db, SyncRepo(api, db));

    final r = await downloads.downloadMore();

    expect(r.downloaded, 3);
    await db.close();
  });
}
