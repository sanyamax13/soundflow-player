import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/core/notice.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_offer.dart';
import 'package:soundflow/data/sync_repo.dart';

/// «Что ждёт телефон на компьютере»: предложение (одна строка и кнопка) вместо
/// двух кнопок «Скачать музыку» и «Синхронизировать сейчас» (Alex TG 20158,
/// 20167). Ничего не качается, пока не нажмёшь.
class _FakeApi extends Api {
  _FakeApi({this.add = const [], this.remove = const []});
  List<Map<String, dynamic>> add;
  List<String> remove;
  bool offline = false;
  int acks = 0;
  int downloads = 0;

  @override
  Future<({List<Map<String, dynamic>> add, List<String> remove, String createdAt})?>
      deviceSyncPlan(String deviceId) async {
    if (offline) throw Exception('нет связи');
    if (add.isEmpty && remove.isEmpty) return null;
    return (add: add, remove: remove, createdAt: 'x');
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
    downloads++;
    await File(toPath).writeAsBytes([1, 2, 3]);
  }

  @override
  Future<void> downloadCover(String url, String toPath) async {}
}

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
}

Map<String, dynamic> _card(String id, int size) =>
    {'id': id, 'title': 'Песня $id', 'artist': 'X', 'size_bytes': size};

const _mb = 1024 * 1024;
const _gb = 1024 * _mb;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // rootNavigatorKey.currentContext
  setUpAll(sqfliteFfiInit);

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('soundflow_offer_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
    Notice.hide();
  });
  tearDown(() {
    Notice.hide();
    tmp.deleteSync(recursive: true);
  });

  Future<(SyncOffer, _FakeApi, Db)> make({
    required _FakeApi api,
    int? free = 48 * _gb,
    bool home = true,
    bool auto = true,
  }) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final repo = DownloadsRepo(api, db, SyncRepo(api, db));
    return (
      SyncOffer(repo, freeSpace: () async => free, atHome: () async => home, autoDownload: auto),
      api,
      db,
    );
  }

  test('есть новое — предложение с числом, размером и свободным местом', () async {
    final (offer, _, db) = await make(api: _FakeApi(add: [_card('a', 50 * _mb), _card('b', 35 * _mb)]));

    await offer.refresh(announce: false);

    expect(offer.hasOffer, isTrue);
    expect(offer.addTitle, 'На компьютере 2 новые песни (85 МБ)');
    expect(offer.addSubtitle, 'На телефоне свободно 48 ГБ');
    expect(offer.lowSpace, isFalse);
    await db.close();
  });

  test('места не хватает — предложение красное', () async {
    final (offer, _, db) = await make(
      api: _FakeApi(add: [_card('a', 5 * _gb)]),
      free: 5 * _gb + 100 * _mb, // влезает впритык, но без запаса в 1 ГБ
    );

    await offer.refresh(announce: false);

    expect(offer.lowSpace, isTrue);
    expect(offer.addSubtitle, startsWith('Не хватит места'));
    await db.close();
  });

  test('на компьютере убрали — предложение стереть', () async {
    final (offer, api, db) = await make(api: _FakeApi(remove: ['x1', 'x2']));
    await db.upsertDownloaded(DownloadedTrack(
        id: 'x1', title: 'x1', artist: 'X', path: '${tmp.path}/x1', bytes: 1, addedAt: 1));
    await db.upsertDownloaded(DownloadedTrack(
        id: 'x2', title: 'x2', artist: 'X', path: '${tmp.path}/x2', bytes: 1, addedAt: 1));

    await offer.refresh(announce: false);

    expect(offer.preview.removeCount, 2);
    expect(offer.removeTitle, 'На компьютере убрали 2 песни');
    expect(api.acks, 0);
    await db.close();
  });

  // 26.09.2026 (разбор Gemini «плашки»): плашки-предложения с кнопками больше нет —
  // дома по Wi-Fi новое качается само, после — короткая плашка без кнопок.
  test('дома по Wi-Fi новое качается само, плашка «Скачано …» без кнопок', () async {
    final (offer, api, db) = await make(api: _FakeApi(add: [_card('a', 10 * _mb), _card('b', 10 * _mb)]));

    await offer.refresh();

    expect(api.downloads, 2);
    final n = Notice.current.value!;
    expect(n.title, 'Скачано 2 новые песни');
    expect(n.actions, isEmpty);
    await db.close();
  });

  test('не дома, выключено или мало места — само не качает и плашек не показывает', () async {
    final (o1, a1, d1) = await make(api: _FakeApi(add: [_card('a', 10 * _mb)]), home: false);
    await o1.refresh();
    expect(a1.downloads, 0);
    expect(Notice.current.value, isNull);

    final (o2, a2, d2) = await make(api: _FakeApi(add: [_card('a', 10 * _mb)]), auto: false);
    await o2.refresh();
    expect(a2.downloads, 0);
    expect(o2.hasOffer, isTrue, reason: 'карточка с кнопкой остаётся');

    final (o3, a3, d3) = await make(api: _FakeApi(add: [_card('a', 10 * _gb)]), free: 2 * _gb);
    await o3.refresh();
    expect(a3.downloads, 0);
    expect(o3.lowSpace, isTrue);
    await d1.close();
    await d2.close();
    await d3.close();
  });

  test('убранное на компьютере само не стирается', () async {
    final (offer, api, db) = await make(api: _FakeApi(remove: ['x1']));
    await db.upsertDownloaded(DownloadedTrack(
        id: 'x1', title: 'x1', artist: 'X', path: '${tmp.path}/x1', bytes: 1, addedAt: 1));
    await offer.refresh();
    expect(offer.preview.removeCount, 1);
    expect(await db.downloadedById('x1'), isNotNull);
    await db.close();
  });

  test('«Скачать» качает, счётчик прогонов растёт, план закрывается', () async {
    final (offer, api, db) = await make(api: _FakeApi(add: [_card('a', 10 * _mb), _card('b', 10 * _mb)]));
    await offer.refresh(announce: false);

    await offer.run(adds: true, removes: false);

    expect(api.downloads, 2);
    expect(offer.runs, 1);
    expect(offer.running, isFalse);
    expect(Notice.current.value!.title, 'Готово');
    expect(Notice.current.value!.subtitle, 'Скачано 2');
    expect(api.acks, greaterThan(0));
    await db.close();
  });

  // 27.09.2026 (разбор Gemini и Алисы): окна «Мало места» больше нет — карточка сама пишет красным,
  // сколько не хватает, а кнопка называется «Всё равно скачать» и качает без второго вопроса.
  test('мало места — карточка пишет, сколько не хватает; «Всё равно скачать» качает без вопроса', () async {
    final (offer, api, db) = await make(api: _FakeApi(add: [_card('a', 10 * _gb)]), free: 2 * _gb);
    await offer.refresh(announce: false);

    expect(offer.lowSpace, isTrue);
    expect(offer.addSubtitle, startsWith('Не хватит места: нужно ещё'));
    await offer.run(adds: true, removes: false);

    expect(api.downloads, 1);
    await db.close();
  });

  test('нет связи с компьютером — карточка это знает, ничего не падает', () async {
    final api = _FakeApi()..offline = true;
    final (offer, _, db) = await make(api: api);

    await offer.refresh();

    expect(offer.lastCheckFailed, isTrue);
    expect(offer.hasOffer, isFalse);
    expect(Notice.current.value, isNull);
    await db.close();
  });
}
