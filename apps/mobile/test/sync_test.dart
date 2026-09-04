import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/db.dart';

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
