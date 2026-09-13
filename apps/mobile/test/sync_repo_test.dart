import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/sync_repo.dart';

class _FakeApiForCentroids extends Api {
  _FakeApiForCentroids({required this.hash, this.onHashCall, this.onCentroidsCall});
  final String hash;
  final void Function()? onHashCall;
  final void Function()? onCentroidsCall;

  @override
  Future<List<String>> postSyncEvents({
    required String deviceId,
    required List<Map<String, Object?>> events,
    int musicBytes = 0,
    String deviceName = 'Android',
    String transport = '',
  }) async =>
      [for (final e in events) '${e['uuid']}'];

  @override
  Future<String?> tasteCentroidsHash() async {
    onHashCall?.call();
    return hash;
  }

  @override
  Future<TasteCentroids?> tasteCentroids() async {
    onCentroidsCall?.call();
    return TasteCentroids(hash: hash, longTerm: const [], recent: const []);
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  Future<Db> freshDb() =>
      Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

  test('после синка тянет centroids только если хэш изменился', () async {
    final calls = <String>[];
    final api = _FakeApiForCentroids(
      hash: 'h1',
      onHashCall: () => calls.add('hash'),
      onCentroidsCall: () => calls.add('centroids'),
    );
    final db = await freshDb();
    final sync = SyncRepo(api, db);
    await sync.record('like', trackId: 't1');

    await sync.sync();
    expect(calls, ['hash', 'centroids']);
    expect(await db.kvGet('taste_centroids_hash'), 'h1');

    calls.clear();
    await sync.record('like', trackId: 't2');
    await sync.sync();
    // хэш не поменялся на сервере — centroids второй раз не тянем
    expect(calls, ['hash']);

    await db.close();
  });

  test('синк без ожидающих событий тоже проверяет хэш вкуса', () async {
    final calls = <String>[];
    final api = _FakeApiForCentroids(
      hash: 'h2',
      onHashCall: () => calls.add('hash'),
      onCentroidsCall: () => calls.add('centroids'),
    );
    final db = await freshDb();
    final sync = SyncRepo(api, db);

    await sync.sync(); // очередь пуста

    expect(calls, ['hash', 'centroids']);
    expect(await db.kvGet('taste_centroids_hash'), 'h2');

    await db.close();
  });
}
