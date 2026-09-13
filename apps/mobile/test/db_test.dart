import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/db.dart';

void main() {
  setUpAll(() => sqfliteFfiInit());

  test('вектор трека сохраняется и читается отдельной таблицей', () async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

    expect(await db.trackVector('t1'), isNull);

    final vec = Uint8List.fromList(List.generate(8192, (i) => i % 256));
    await db.setTrackVector('t1', vec);
    final got = await db.trackVector('t1');
    expect(got, isNotNull);
    expect(got, vec);

    // перезапись тем же id — не дублирует строку
    final vec2 = Uint8List.fromList(List.filled(8192, 7));
    await db.setTrackVector('t1', vec2);
    expect(await db.trackVector('t1'), vec2);

    await db.setTrackVector('t2', vec);
    final many = await db.trackVectorsFor(['t1', 't2', 'missing']);
    expect(many.length, 2);
    expect(many['t1'], vec2);
    expect(many['t2'], vec);
    expect(many.containsKey('missing'), isFalse);

    await db.close();
  });

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
