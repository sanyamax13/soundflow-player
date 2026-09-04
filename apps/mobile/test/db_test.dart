import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/db.dart';

void main() {
  setUpAll(() => sqfliteFfiInit());

  test('скачанный трек сохраняется и читается', () async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

    expect(await db.downloadedById('t1'), isNull);

    await db.upsertDownloaded(DownloadedTrack(
      id: 't1', title: 'Песня', artist: 'Кто-то',
      path: '/tmp/t1', bytes: 1234, addedAt: 1,
    ));

    final row = await db.downloadedById('t1');
    expect(row, isNotNull);
    expect(row!.title, 'Песня');
    expect(row.bytes, 1234);
    expect((await db.allDownloaded()).length, 1);

    // повторная запись того же id не плодит дубли
    await db.upsertDownloaded(DownloadedTrack(
      id: 't1', title: 'Песня 2', artist: 'Кто-то',
      path: '/tmp/t1', bytes: 9999, addedAt: 2,
    ));
    expect((await db.allDownloaded()).length, 1);
    expect((await db.downloadedById('t1'))!.title, 'Песня 2');

    await db.close();
  });
}
