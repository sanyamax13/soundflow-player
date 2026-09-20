import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';

/// План с компьютера (что скачать / что стереть) выполняется только по нажатию
/// на телефоне, «Стоп» его прерывает, а на сервере план закрывается, только
/// когда на телефоне по нему больше нечего делать (ревизия 20.09.2026, п. 1в:
/// раньше подтверждение слалось даже при ошибках — недокачанное терялось).
class _FakeApi extends Api {
  _FakeApi({this.add = const [], this.remove = const []});

  final List<Map<String, dynamic>> add;
  final List<String> remove;
  final Set<String> failIds = {};
  int acks = 0;

  @override
  Future<({List<Map<String, dynamic>> add, List<String> remove, String createdAt})?>
      deviceSyncPlan(String deviceId) async {
    if (add.isEmpty && remove.isEmpty) return null;
    return (add: add, remove: remove, createdAt: '2026-09-20T00:00:00Z');
  }

  @override
  Future<void> ackSyncPlan(String deviceId) async => acks++;

  @override
  Future<void> syncProgress({
    required String deviceId,
    required int done,
    required int total,
    required String current,
    required bool active,
  }) async {}

  @override
  Future<Map<String, Uint8List>> trackVectors(List<String> ids) async => {};

  @override
  Future<void> downloadTrack(String id, String toPath) async {
    await File(toPath).writeAsBytes([1, 2, 3]);
    if (failIds.contains(id)) throw Exception('оборвалось');
  }
}

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
}

Map<String, dynamic> _card(String id, {int size = 1000}) =>
    {'id': id, 'title': 'Песня $id', 'artist': 'X', 'size_bytes': size};

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('soundflow_plan_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Db> freshDb() => Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

  // isDownloaded() смотрит и в базу, и на файл — файл тоже кладём.
  DownloadedTrack row(String id) {
    final f = File('${tmp.path}/music/$id')..createSync(recursive: true);
    f.writeAsBytesSync([1, 2, 3]);
    return DownloadedTrack(id: id, title: id, artist: 'X', path: f.path, bytes: 3, addedAt: 1);
  }

  test('previewPlan считает только то, что ещё не сделано на этом телефоне', () async {
    final db = await freshDb();
    // «a» уже скачана, «old1» на телефоне лежит, «gone» — нет
    await db.upsertDownloaded(row('a'));
    await db.upsertDownloaded(row('old1'));
    final api = _FakeApi(
      add: [_card('a'), _card('b', size: 500), _card('c', size: 700)],
      remove: ['old1', 'gone'],
    );
    final repo = DownloadsRepo(api, db, SyncRepo(api, db));

    final p = await repo.previewPlan();

    expect(p.addCount, 2);
    expect(p.addBytes, 1200);
    expect(p.removeCount, 1);
    expect(api.acks, 0, reason: 'смотрим — ничего не подтверждаем');
    await db.close();
  });

  test('previewPlan: делать нечего — план тихо закрывается', () async {
    final db = await freshDb();
    await db.upsertDownloaded(row('a'));
    final api = _FakeApi(add: [_card('a')], remove: ['gone']);
    final repo = DownloadsRepo(api, db, SyncRepo(api, db));

    final p = await repo.previewPlan();

    expect(p.isEmpty, isTrue);
    expect(api.acks, 1);
    await db.close();
  });

  test('applyPendingPlan: всё скачано и стёрто — план закрыт', () async {
    final db = await freshDb();
    await db.upsertDownloaded(row('old1'));
    final api = _FakeApi(add: [_card('a'), _card('b')], remove: ['old1']);
    final repo = DownloadsRepo(api, db, SyncRepo(api, db));

    final r = await repo.applyPendingPlan();

    expect((r.added, r.removed, r.failed, r.stopped), (2, 1, 0, false));
    expect(await db.downloadedById('a'), isNotNull);
    expect(await db.downloadedById('old1'), isNull);
    expect(api.acks, 1);
    await db.close();
  });

  test('песня не скачалась — план НЕ закрывается, обрубок файла убран', () async {
    final db = await freshDb();
    final api = _FakeApi(add: [_card('a'), _card('b')]);
    api.failIds.add('b');
    final repo = DownloadsRepo(api, db, SyncRepo(api, db));

    final r = await repo.applyPendingPlan();

    expect((r.added, r.failed), (1, 1));
    expect(api.acks, 0, reason: 'недокачанное должно предложиться снова');
    expect(File('${tmp.path}/music/b').existsSync(), isFalse);
    await db.close();
  });

  test('«Стоп» посреди — скачанное остаётся, дальше не идёт, план не закрыт', () async {
    final db = await freshDb();
    final api = _FakeApi(add: [for (var i = 0; i < 5; i++) _card('t$i')]);
    final repo = DownloadsRepo(api, db, SyncRepo(api, db));
    final token = DownloadCancelToken();

    final r = await repo.applyPendingPlan(
      cancelToken: token,
      onProgress: (done, total, title) {
        // Отмена проверяется в НАЧАЛЕ следующей песни: та, что уже идёт,
        // докачивается до конца.
        if (done == 1) token.cancel();
      },
    );

    expect(r.added, 2);
    expect(r.stopped, isTrue);
    expect((await db.allDownloaded()).length, 2);
    expect(api.acks, 0);
    await db.close();
  });

  test('только «Скачать» — стирать не трогает, план остаётся до «Стереть»', () async {
    final db = await freshDb();
    await db.upsertDownloaded(row('old1'));
    final api = _FakeApi(add: [_card('a')], remove: ['old1']);
    final repo = DownloadsRepo(api, db, SyncRepo(api, db));

    final r = await repo.applyPendingPlan(removes: false);

    expect((r.added, r.removed), (1, 0));
    expect(await db.downloadedById('old1'), isNotNull);
    expect(api.acks, 0);

    final r2 = await repo.applyPendingPlan(adds: false);
    expect(r2.removed, 1);
    expect(api.acks, 1);
    await db.close();
  });
}
