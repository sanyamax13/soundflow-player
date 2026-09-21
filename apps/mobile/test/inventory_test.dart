import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';

/// Точный список песен телефона для сверки с компьютером (Alex TG 20277–20279, 21.09.2026): уходит только с
/// реально лежащими файлами, не чаще нужного, а нет связи — тихо и повторится позже.
class _FakeApi extends Api {
  final List<List<({String id, int bytes})>> sent = [];
  final List<String> devices = [];
  bool offline = false;

  @override
  Future<void> sendInventory(String deviceId, List<({String id, int bytes})> items) async {
    if (offline) throw Exception('нет связи');
    devices.add(deviceId);
    sent.add(items);
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
    tmp = Directory.systemTemp.createTempSync('soundflow_inventory_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Db> freshDb() => Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

  Future<void> onPhone(Db db, String id, {int bytes = 3, bool withFile = true}) async {
    final f = File('${tmp.path}/music/$id');
    if (withFile) {
      f.createSync(recursive: true);
      f.writeAsBytesSync(List.filled(bytes, 1));
    }
    await db.upsertDownloaded(DownloadedTrack(id: id, title: id, artist: 'X', path: f.path, bytes: bytes, addedAt: 1));
  }

  DownloadsRepo repoOf(_FakeApi api, Db db) => DownloadsRepo(api, db, SyncRepo(api, db));

  test('уходит id и размер песен, чей файл реально есть; без файла — не в списке', () async {
    final db = await freshDb();
    await onPhone(db, 'a', bytes: 4);
    await onPhone(db, 'b', bytes: 6);
    await onPhone(db, 'nofile', withFile: false);
    final api = _FakeApi();

    await repoOf(api, db).reportInventory();

    expect(api.sent, hasLength(1));
    expect({for (final i in api.sent.single) i.id: i.bytes}, {'a': 4, 'b': 6});
    expect(api.devices.single, isNotEmpty);
    await db.close();
  });

  test('ничего не изменилось — второй раз не шлём; появилась песня — шлём снова', () async {
    final db = await freshDb();
    await onPhone(db, 'a');
    final api = _FakeApi();
    final repo = repoOf(api, db);

    await repo.reportInventory();
    await repo.reportInventory();
    expect(api.sent, hasLength(1));

    await onPhone(db, 'b');
    await repo.reportInventory();
    expect(api.sent, hasLength(2));
    expect(api.sent.last.map((i) => i.id).toSet(), {'a', 'b'});
    await db.close();
  });

  test('нет связи — тихо, без исключения; в следующий раз шлём', () async {
    final db = await freshDb();
    await onPhone(db, 'a');
    final api = _FakeApi()..offline = true;
    final repo = repoOf(api, db);

    await repo.reportInventory();
    expect(api.sent, isEmpty);

    api.offline = false;
    await repo.reportInventory();
    expect(api.sent, hasLength(1), reason: 'неудачная отправка не должна помечаться как сделанная');
    await db.close();
  });

  test('два вызова подряд — одна отправка', () async {
    final db = await freshDb();
    await onPhone(db, 'a');
    final api = _FakeApi();
    final repo = repoOf(api, db);

    await Future.wait([repo.reportInventory(), repo.reportInventory()]);

    expect(api.sent, hasLength(1));
    await db.close();
  });
}
