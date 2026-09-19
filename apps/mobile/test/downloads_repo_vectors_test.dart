import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
}

class _FakeApi extends Api {
  _FakeApi({this.vectorFor});
  final Uint8List? Function(String id)? vectorFor;
  void Function(List<String> ids)? onTrackVectorsCall;

  @override
  Future<void> downloadTrack(String id, String toPath) async {
    await File(toPath).create(recursive: true);
  }

  @override
  Future<Map<String, Uint8List>> trackVectors(List<String> ids) async {
    onTrackVectorsCall?.call(ids);
    if (vectorFor == null) throw Exception('network down');
    final out = <String, Uint8List>{};
    for (final id in ids) {
      final v = vectorFor!(id);
      if (v != null) out[id] = v;
    }
    return out;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('soundflow_vectors_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('скачивание сохраняет отпечаток трека', () async {
    final vec = Uint8List.fromList(List.filled(8, 5));
    final api = _FakeApi(vectorFor: (id) => id == 't1' ? vec : null);
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final repo = DownloadsRepo(api, db);

    await repo.download({'id': 't1', 'title': 'T', 'artist': 'A'});

    expect(await db.trackVector('t1'), vec);
    await db.close();
  });

  test('нет сети для отпечатка — скачивание всё равно успешно', () async {
    final api = _FakeApi(vectorFor: null); // trackVectors бросит исключение
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final repo = DownloadsRepo(api, db);

    final size = await repo.download({'id': 't1', 'title': 'T', 'artist': 'A'});

    expect(size, isA<int>());
    expect(await db.trackVector('t1'), isNull);
    expect(await db.downloadedById('t1'), isNotNull);
    await db.close();
  });

  test('backfillVectors докачивает отпечатки только тем, у кого их нет', () async {
    final calls = <List<String>>[];
    final vec = Uint8List.fromList(List.filled(8, 9));
    final api = _FakeApi(vectorFor: (id) => vec)..onTrackVectorsCall = calls.add;
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final repo = DownloadsRepo(api, db);
    await db.upsertDownloaded(DownloadedTrack(id: 'old1', title: 'x', artist: 'y', path: '/tmp/old1', bytes: 1, addedAt: 1));
    await db.upsertDownloaded(DownloadedTrack(id: 'old2', title: 'x', artist: 'y', path: '/tmp/old2', bytes: 1, addedAt: 2));
    await db.setTrackVector('old2', vec); // у old2 уже есть — не должен попасть в запрос

    await repo.backfillVectors();

    expect(calls, isNotEmpty);
    expect(calls.expand((x) => x), contains('old1'));
    expect(calls.expand((x) => x), isNot(contains('old2')));
    expect(await db.trackVector('old1'), vec);
    await db.close();
  });

  test('backfillVectors: два вызова одновременно — один прогон, один поход на сервер', () async {
    // Зовут и при старте приложения, и когда радио не нашло отпечаток —
    // одновременно два прогона по всей библиотеке не нужны (19.09.2026).
    final calls = <List<String>>[];
    final vec = Uint8List.fromList(List.filled(8, 9));
    final api = _FakeApi(vectorFor: (id) => vec)..onTrackVectorsCall = calls.add;
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final repo = DownloadsRepo(api, db);
    await db.upsertDownloaded(DownloadedTrack(id: 'x1', title: 'x', artist: 'y', path: '/tmp/x1', bytes: 1, addedAt: 1));

    await Future.wait([repo.backfillVectors(), repo.backfillVectors()]);
    expect(calls, hasLength(1));

    // Флажок «идёт прогон» не залип: новый недостающий отпечаток докачается
    // следующим вызовом.
    await db.upsertDownloaded(DownloadedTrack(id: 'x2', title: 'x', artist: 'y', path: '/tmp/x2', bytes: 1, addedAt: 2));
    await repo.backfillVectors();
    expect(calls, hasLength(2));
    expect(calls.last, ['x2']);
    expect(await db.trackVector('x2'), vec);
    await db.close();
  });

  test('backfillVectors: сети нет — не падает и не залипает, повтор пробует снова', () async {
    final calls = <List<String>>[];
    final api = _FakeApi(vectorFor: null)..onTrackVectorsCall = calls.add; // trackVectors бросает
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final repo = DownloadsRepo(api, db);
    await db.upsertDownloaded(DownloadedTrack(id: 'x1', title: 'x', artist: 'y', path: '/tmp/x1', bytes: 1, addedAt: 1));

    await repo.backfillVectors(); // без исключения наружу
    await repo.backfillVectors(); // и второй раз тоже честно пробует
    expect(calls, hasLength(2));
    expect(await db.trackVector('x1'), isNull);
    await db.close();
  });
}
