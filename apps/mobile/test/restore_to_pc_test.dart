import 'dart:io';

import 'package:dio/dio.dart' show DioException;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';

/// Разовый возврат песен на компьютер (Alex TG 20261–20269, 21.09.2026): телефон сам отдаёт то, что просит ПК,
/// а чего нет — сообщает. Тихо: ни ошибок наружу, ни лишних запросов.
class _FakeApi extends Api {
  _FakeApi(this.wanted);

  final List<Map<String, dynamic>> wanted;
  final List<String> uploaded = [];
  final List<String> reportedMissing = [];
  final Set<String> rejectIds = {};
  String? failAt; // на этой песне «пропала связь»
  bool noServer = false; // старая программа на ПК: ручки нет
  int wantedCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> restoreWanted() async {
    wantedCalls++;
    if (noServer) throw Exception('404');
    return wanted;
  }

  @override
  Future<bool> restoreUpload(String id, File file) async {
    if (id == failAt) throw Exception('связь пропала');
    uploaded.add(id);
    return !rejectIds.contains(id);
  }

  @override
  Future<void> restoreMissing(List<String> ids) async => reportedMissing.addAll(ids);
}

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
}

Map<String, dynamic> _want(String id) => {'id': id, 'artist': 'X', 'title': 'Песня $id', 'size_bytes': 3};

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('soundflow_restore_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Db> freshDb() => Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

  Future<void> onPhone(Db db, String id, {bool withFile = true}) async {
    final f = File('${tmp.path}/music/$id')..createSync(recursive: true);
    if (withFile) f.writeAsBytesSync([1, 2, 3]);
    await db.upsertDownloaded(DownloadedTrack(id: id, title: id, artist: 'X', path: f.path, bytes: 3, addedAt: 1));
  }

  test('что есть на телефоне — отдаётся, чего нет — сообщается', () async {
    final db = await freshDb();
    await onPhone(db, 'a');
    await onPhone(db, 'b');
    await onPhone(db, 'nofile', withFile: false); // запись есть, файл пропал
    final api = _FakeApi([_want('a'), _want('b'), _want('never'), _want('nofile')]);

    await DownloadsRepo(api, db).returnFilesToPc();

    expect(api.uploaded, ['a', 'b']);
    expect(api.reportedMissing, ['never', 'nofile']);
    await db.close();
  });

  test('список пуст — только один запрос, больше ничего', () async {
    final db = await freshDb();
    final api = _FakeApi([]);

    await DownloadsRepo(api, db).returnFilesToPc();

    expect(api.wantedCalls, 1);
    expect(api.uploaded, isEmpty);
    expect(api.reportedMissing, isEmpty);
    await db.close();
  });

  test('связь пропала посреди возврата — остановились, «нет на телефоне» не шлём', () async {
    final db = await freshDb();
    await onPhone(db, 'a');
    await onPhone(db, 'b');
    await onPhone(db, 'c');
    final api = _FakeApi([_want('a'), _want('b'), _want('never'), _want('c')])..failAt = 'b';

    await DownloadsRepo(api, db).returnFilesToPc();

    expect(api.uploaded, ['a']);
    expect(api.reportedMissing, isEmpty, reason: 'не дошли до конца — не знаем, что осталось; скажем в следующий раз');
    await db.close();
  });

  test('компьютер не принял файл — идём дальше, повторять не пытаемся', () async {
    final db = await freshDb();
    await onPhone(db, 'a');
    await onPhone(db, 'b');
    final api = _FakeApi([_want('a'), _want('b')])..rejectIds.add('a');

    await DownloadsRepo(api, db).returnFilesToPc();

    expect(api.uploaded, ['a', 'b']);
    await db.close();
  });

  test('старая программа на компьютере (ручки нет) — тихо, без исключения', () async {
    final db = await freshDb();
    final api = _FakeApi([_want('a')])..noServer = true;

    await DownloadsRepo(api, db).returnFilesToPc();

    expect(api.uploaded, isEmpty);
    await db.close();
  });

  test('Api.restoreUpload: файл уходит PUT-ом целиком с длиной, 4xx → false, сбой на ПК → исключение', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    var status = 200;
    String? method, path, ctype;
    int? length;
    List<int> received = [];
    server.listen((req) async {
      method = req.method;
      path = req.uri.path;
      length = req.contentLength;
      ctype = req.headers.contentType?.mimeType;
      received = [for (final chunk in await req.toList()) ...chunk];
      req.response.statusCode = status;
      req.response.write('{}');
      await req.response.close();
    });
    final api = Api(baseUrl: 'http://127.0.0.1:${server.port}');
    final f = File('${tmp.path}/song.mp3')..writeAsBytesSync(List.generate(5000, (i) => i % 251));

    expect(await api.restoreUpload('abc', f), isTrue);
    expect((method, path, length, ctype), ('PUT', '/api/restore/upload/abc', 5000, 'application/octet-stream'));
    expect(received, f.readAsBytesSync());

    status = 422;
    expect(await api.restoreUpload('abc', f), isFalse, reason: 'ПК не принял файл — повторять незачем');
    status = 503;
    await expectLater(api.restoreUpload('abc', f), throwsA(isA<DioException>()));
  });

  test('два вызова подряд — один прогон', () async {
    final db = await freshDb();
    await onPhone(db, 'a');
    final api = _FakeApi([_want('a')]);
    final repo = DownloadsRepo(api, db);

    await Future.wait([repo.returnFilesToPc(), repo.returnFilesToPc()]);

    expect(api.wantedCalls, 1);
    expect(api.uploaded, ['a']);
    await db.close();
  });
}
