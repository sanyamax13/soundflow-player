import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';

/// Лёгкие выборки для фоновых сверок (оптимизация 21.09.2026, Alex TG 20331): те же ответы, что давали
/// тяжёлые «загрузить всё и посчитать», но без чтения всей библиотеки и без обхода файлов по одному.
class _FakeApi extends Api {
  final List<String> coverRequests = [];

  @override
  Future<void> downloadCover(String url, String toPath) async {
    coverRequests.add(toPath);
    await File(toPath).create(recursive: true);
  }

  @override
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async => [
        {'id': 'meta1', 'mime_type': 'audio/mpeg', 'bitrate_kbps': 320, 'duration_sec': 201},
      ];
}

/// Компьютер уже починил имя (было «??????» на телефоне).
class _FixedNameApi extends _FakeApi {
  @override
  Future<List<Map<String, dynamic>>> tracks({int? limit}) async => [
        {'id': 'broken', 'artist': 'Земфира', 'title': 'Хочешь?', 'mime_type': 'audio/mpeg'},
      ];
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
    tmp = Directory.systemTemp.createTempSync('soundflow_light_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Db> freshDb() => Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

  DownloadedTrack track(String id,
          {int bytes = 10,
          String? cover,
          String? format,
          int? kbps,
          int? sec,
          String? path,
          double? energy,
          String? album,
          String? genre}) =>
      DownloadedTrack(
        id: id,
        title: id,
        artist: 'A',
        path: path ?? '${tmp.path}/music/$id',
        bytes: bytes,
        addedAt: 1,
        coverPath: cover,
        format: format,
        bitrateKbps: kbps,
        durationSec: sec,
        album: album,
        genre: genre,
        energy: energy,
      );

  group('existingFiles', () {
    test('мало файлов в папке — проверка по одному; есть и нет', () async {
      File('${tmp.path}/a.jpg').writeAsBytesSync([1]);
      final got = await existingFiles(['${tmp.path}/a.jpg', '${tmp.path}/нет.jpg']);
      expect(got, {'${tmp.path}/a.jpg'});
    });

    test('много файлов в папке — читается один раз списком, ответ тот же', () async {
      final dir = Directory('${tmp.path}/covers')..createSync();
      final want = <String>[];
      for (var i = 0; i < 200; i++) {
        if (i.isEven) File('${dir.path}/t$i.jpg').writeAsBytesSync([1]);
        want.add('${dir.path}/t$i.jpg');
      }
      // лишний файл, о котором не спрашивали, в ответ не попадает
      File('${dir.path}/чужой.jpg').writeAsBytesSync([1]);
      final got = await existingFiles(want);
      expect(got.length, 100);
      expect(got.every((p) => want.contains(p)), isTrue);
      expect(got.contains('${dir.path}/t0.jpg'), isTrue);
      expect(got.contains('${dir.path}/t1.jpg'), isFalse);
    });

    test('папки нет, пустой путь, путь без папки — не падает, файлов «нет»', () async {
      final got = await existingFiles(['${tmp.path}/нет-такой/a.jpg', '', 'без_папки.jpg']);
      expect(got, isEmpty);
    });

    test('несколько папок за один вызов', () async {
      File('${tmp.path}/x.jpg').writeAsBytesSync([1]);
      Directory('${tmp.path}/sub').createSync();
      File('${tmp.path}/sub/y.jpg').writeAsBytesSync([1]);
      final got = await existingFiles(['${tmp.path}/x.jpg', '${tmp.path}/sub/y.jpg', '${tmp.path}/sub/z.jpg']);
      expect(got, {'${tmp.path}/x.jpg', '${tmp.path}/sub/y.jpg'});
    });
  });

  group('лёгкие запросы базы', () {
    test('downloadedStats — число и вес без чтения песен; пусто — нули', () async {
      final db = await freshDb();
      expect(await db.downloadedStats(), (count: 0, bytes: 0));
      await db.upsertDownloaded(track('a', bytes: 5));
      await db.upsertDownloaded(track('b', bytes: 7));
      expect(await db.downloadedStats(), (count: 2, bytes: 12));
      await db.close();
    });

    test('idsNeedingMeta — только те, у кого нет ни формата, ни битрейта, ни длины, ни энергии',
        () async {
      final db = await freshDb();
      // 25.09.2026: idsNeedingMeta теперь ловит ещё и energy IS NULL (фильтр
      // «Настроение») — у «полных» записей energy тоже должна быть задана,
      // иначе их снова засчитает как «нуждается в докачке».
      await db.upsertDownloaded(track('empty'));
      await db.upsertDownloaded(track('emptyFormat', format: ''));
      // 26.09.2026: и альбом — NULL значит «ещё не спрашивали сервер», '' — «альбома нет».
      // И жанр: NULL — не спрашивали, '' — сервер ещё не знает (спросим снова).
      await db.upsertDownloaded(track('hasFormat', format: 'mp3', energy: 0.5, album: 'X', genre: 'pop'));
      await db.upsertDownloaded(track('hasKbps', kbps: 320, energy: 0.5, album: '', genre: 'rock'));
      await db.upsertDownloaded(track('hasSec', sec: 200, energy: 0.5, album: 'Y', genre: 'rusrap'));
      await db.upsertDownloaded(track('noAlbumYet', sec: 200, energy: 0.5, genre: 'pop'));
      await db.upsertDownloaded(track('genreUnknownYet', sec: 200, energy: 0.5, album: 'Z', genre: ''));
      // 26.09.2026: и громкость (loudness IS NULL — ещё не пришла с сервера) — «полным» ставим.
      for (final id in ['hasFormat', 'hasKbps', 'hasSec', 'noAlbumYet', 'genreUnknownYet']) {
        await db.updateMeta(id, loudness: -10, mood: 'happy');
      }
      expect((await db.idsNeedingMeta())..sort(), ['empty', 'emptyFormat', 'genreUnknownYet', 'noAlbumYet']);
      await db.close();
    });

    test('vectorIds и downloadedIds — только id, без самих отпечатков', () async {
      final db = await freshDb();
      await db.upsertDownloaded(track('a'));
      await db.upsertDownloaded(track('b'));
      await db.setTrackVector('a', Uint8List.fromList([1, 2, 3]));
      expect(await db.vectorIds(), {'a'});
      expect((await db.downloadedIds())..sort(), ['a', 'b']);
      await db.close();
    });

    test('coverRows и fileRows отдают id, путь и вес', () async {
      final db = await freshDb();
      await db.upsertDownloaded(track('a', bytes: 9, cover: '/c/a.jpg'));
      await db.upsertDownloaded(track('b', bytes: 4));
      final covers = {for (final r in await db.coverRows()) r.id: r.coverPath};
      expect(covers, {'a': '/c/a.jpg', 'b': null});
      final files = {for (final r in await db.fileRows()) r.id: (r.path, r.bytes)};
      expect(files['a'], ('${tmp.path}/music/a', 9));
      expect(files['b'], ('${tmp.path}/music/b', 4));
      await db.close();
    });

    test('trackVectorsFor: больше 400 id за раз — читается кусками, ответ полный', () async {
      final db = await freshDb();
      final ids = [for (var i = 0; i < 1234; i++) 'v$i'];
      for (final id in ids) {
        await db.setTrackVector(id, Uint8List.fromList([id.length]));
      }
      final got = await db.trackVectorsFor([...ids, 'нет-такого']);
      expect(got.length, 1234);
      expect(got['v0'], [2]);
      expect(got['v1233'], [5]);
      expect(await db.trackVectorsFor([]), isEmpty);
      await db.close();
    });
  });

  group('DownloadsRepo: сверки без тяжёлых загрузок', () {
    test('summary: сколько песен, вес, сколько обложек реально на диске', () async {
      final db = await freshDb();
      final repo = DownloadsRepo(_FakeApi(), db);
      File('${tmp.path}/covers-a.jpg').writeAsBytesSync([1]);
      await db.upsertDownloaded(track('a', bytes: 5, cover: '${tmp.path}/covers-a.jpg'));
      await db.upsertDownloaded(track('b', bytes: 7, cover: '${tmp.path}/covers-нет.jpg')); // файла нет
      await db.upsertDownloaded(track('c', bytes: 1)); // обложки нет вовсе
      final s = await repo.summary();
      expect((s.count, s.bytes, s.covers), (3, 13, 1));
      expect(await repo.stats(), (count: 3, bytes: 13));
      await db.close();
    });

    test('backfillCovers докачивает только тем, у кого обложки нет или файл пропал', () async {
      final db = await freshDb();
      final api = _FakeApi();
      final repo = DownloadsRepo(api, db);
      Directory('${tmp.path}/covers').createSync(recursive: true);
      File('${tmp.path}/covers/ok.jpg').writeAsBytesSync([1]);
      await db.upsertDownloaded(track('ok', cover: '${tmp.path}/covers/ok.jpg'));
      await db.upsertDownloaded(track('lost', cover: '${tmp.path}/covers/lost.jpg')); // запись есть, файла нет
      await db.upsertDownloaded(track('none')); // обложки не было

      await repo.backfillCovers();

      expect(api.coverRequests.map((p) => p.split(RegExp(r'[/\\]')).last).toList()..sort(),
          ['lost.jpg', 'none.jpg']);
      final lost = await db.downloadedById('lost');
      expect(lost?.coverPath, endsWith('lost.jpg'));
      await db.close();
    });

    test('backfillMeta: спрашивает каталог только когда есть кому дописывать', () async {
      final db = await freshDb();
      final repo = DownloadsRepo(_FakeApi(), db);
      await db.upsertDownloaded(track('meta1'));
      await db.upsertDownloaded(track('done', format: 'mp3', kbps: 128, sec: 100));

      await repo.backfillMeta();

      final m = await db.downloadedById('meta1');
      expect((m?.format, m?.bitrateKbps, m?.durationSec), ('MP3', 320, 201));
      final d = await db.downloadedById('done');
      expect((d?.format, d?.bitrateKbps, d?.durationSec), ('mp3', 128, 100)); // не тронута
      await db.close();
    });

    // 27.09.2026: телефон брал имя один раз при скачивании — исправленное на компьютере не доходило.
    test('backfillMeta: имя, исправленное на компьютере, приходит на телефон', () async {
      final db = await freshDb();
      final repo = DownloadsRepo(_FixedNameApi(), db);
      await db.upsertDownloaded(DownloadedTrack(
          id: 'broken', title: '??????', artist: '???????', path: '/tmp/broken', bytes: 1, addedAt: 1));

      await repo.backfillMeta(force: true);

      final t = await db.downloadedById('broken');
      expect((t?.artist, t?.title), ('Земфира', 'Хочешь?'));
      await db.close();
    });
  });
}
