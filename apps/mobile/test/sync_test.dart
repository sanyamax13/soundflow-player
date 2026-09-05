import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<Db> freshDb() =>
      Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

  test('очередь событий: запись, счётчик, порядок, пометка отправленным', () async {
    final db = await freshDb();

    expect(await db.pendingCount(), 0);

    await db.enqueueEvent(uuid: 'a', kind: 'like', trackId: 't1', clientTs: 10);
    await db.enqueueEvent(uuid: 'b', kind: 'delete', trackId: 't2', clientTs: 5);
    expect(await db.pendingCount(), 2);

    // тот же uuid второй раз не плодит дубль
    await db.enqueueEvent(uuid: 'a', kind: 'like', trackId: 't1', clientTs: 99);
    expect(await db.pendingCount(), 2);

    // отдаётся по времени события (client_ts ASC)
    final pend = await db.pendingEvents();
    expect(pend.map((e) => e['uuid']).toList(), ['b', 'a']);

    await db.markSynced(['a', 'b']);
    expect(await db.pendingCount(), 0);
    // отправленные из очереди не выдаются
    expect(await db.pendingEvents(), isEmpty);

    await db.close();
  });

  test('markSynced с пустым списком — не падает', () async {
    final db = await freshDb();
    await db.markSynced([]);
    expect(await db.pendingCount(), 0);
    await db.close();
  });

  test('удаление трека с причиной кладёт её в очередь событий (05.09.2026)', () async {
    final db = await freshDb();
    final sync = SyncRepo(Api(), db);
    final downloads = DownloadsRepo(Api(), db, sync);

    await db.upsertDownloaded(DownloadedTrack(
      id: 't1', title: 'Песня', artist: 'Кто-то', path: '/tmp/does-not-exist', bytes: 1, addedAt: 1,
    ));

    await downloads.delete('t1', reason: 'dislike');

    final pend = await db.pendingEvents();
    final del = pend.singleWhere((e) => e['kind'] == 'delete');
    expect(jsonDecode('${del['payload']}'), {'reason': 'dislike'});

    await db.close();
  });

  test('удаление без причины — payload пустой (свайп в «Моей музыке»)', () async {
    final db = await freshDb();
    final sync = SyncRepo(Api(), db);
    final downloads = DownloadsRepo(Api(), db, sync);

    await db.upsertDownloaded(DownloadedTrack(
      id: 't1', title: 'Песня', artist: 'Кто-то', path: '/tmp/does-not-exist', bytes: 1, addedAt: 1,
    ));

    await downloads.delete('t1');

    final pend = await db.pendingEvents();
    final del = pend.singleWhere((e) => e['kind'] == 'delete');
    expect(jsonDecode('${del['payload']}'), <String, Object?>{});

    await db.close();
  });

  test('kv: запись, перезапись, чтение', () async {
    final db = await freshDb();

    expect(await db.kvGet('device_id'), isNull);
    await db.kvSet('device_id', 'xyz');
    expect(await db.kvGet('device_id'), 'xyz');
    await db.kvSet('device_id', 'abc');
    expect(await db.kvGet('device_id'), 'abc');

    await db.close();
  });
}
