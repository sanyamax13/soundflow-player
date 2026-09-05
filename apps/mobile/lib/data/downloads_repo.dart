import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import 'api.dart';
import 'db.dart';
import 'sync_repo.dart';

/// Скачивание треков с сервера в память телефона и учёт скачанного —
/// список «Моя музыка». Правила 50 ГБ, автоподкачка по Wi-Fi — потом.
///
/// Действия пользователя (скачал / удалил / в избранное) заодно кладутся
/// в очередь событий [SyncRepo], чтобы дома уехать на сервер.
class DownloadsRepo {
  DownloadsRepo(this._api, this._db, [this._sync]);

  final Api _api;
  final Db _db;
  final SyncRepo? _sync;

  Future<Directory> _musicDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/music');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<Directory> _coversDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/covers');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<String> localPath(String id) async => '${(await _musicDir()).path}/$id';

  Future<bool> isDownloaded(String id) async {
    final row = await _db.downloadedById(id);
    return row != null && File(row.path).existsSync();
  }

  /// Скачать один трек. Возвращает размер файла в байтах.
  Future<int> download(Map<String, dynamic> track) async {
    final id = '${track['id']}';
    final path = await localPath(id);
    await _api.downloadTrack(id, path);
    final size = await File(path).length();

    // Обложка — необязательно: нет ссылки или сайт с картинкой не ответил —
    // просто играем без неё, трек это не должно останавливать.
    String? coverPath;
    final coverUrl = '${track['cover_url'] ?? ''}';
    if (coverUrl.isNotEmpty) {
      try {
        final cp = '${(await _coversDir()).path}/$id.jpg';
        await _api.downloadCover(coverUrl, cp);
        coverPath = cp;
      } catch (_) {
        coverPath = null;
      }
    }

    await _db.upsertDownloaded(DownloadedTrack(
      id: id,
      title: '${track['title'] ?? id}',
      artist: '${track['artist'] ?? ''}',
      path: path,
      bytes: size,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      coverPath: coverPath,
    ));
    await _sync?.record('download', trackId: id);
    // Был в избранном старого плеера — ставим сердечко (только добавляем).
    if (track['favorite'] == true) {
      await _db.setFavorite(id, true);
      await _sync?.record('like', trackId: id);
    }
    return size;
  }

  /// [reason] — почему убрали (см. player_view.dart, 05.09.2026: Alex
  /// попросил спрашивать причину, чтобы потом было видно, какие песни
  /// правда плохие, а какие просто не по вкусу). Необязательный — старые
  /// места вызова (свайп в «Моей музыке») пока без причины.
  Future<void> delete(String id, {String? reason}) async {
    final row = await _db.downloadedById(id);
    if (row != null) {
      final f = File(row.path);
      if (f.existsSync()) f.deleteSync();
    }
    await _db.deleteDownloaded(id);
    await _sync?.record('delete',
        trackId: id, payload: reason == null ? null : {'reason': reason});
  }

  /// Докачать обложки уже скачанным трекам, у которых их пока нет — чтобы
  /// показывались сразу с диска, без подгрузки по сети каждый раз (05.09.2026,
  /// просьба Alex после того как обложки заработали: "надо сделать всё
  /// офлайн, чтобы обложки не подгружались"). Вызывается фоном при старте
  /// приложения (main.dart) — не мешает пользоваться, пока идёт; не нашлась
  /// обложка сейчас — трек просто остаётся без нее до следующего запуска
  /// (сервер может позже сам найти через другой источник, см. этап 24).
  Future<void> backfillCovers({int concurrency = 5}) async {
    final rows = await _db.allDownloaded();
    final pending = [
      for (final t in rows)
        if (t.coverPath == null || !File(t.coverPath!).existsSync()) t,
    ];
    for (var i = 0; i < pending.length; i += concurrency) {
      await Future.wait(pending.skip(i).take(concurrency).map(_fetchCoverFor));
    }
  }

  Future<void> _fetchCoverFor(DownloadedTrack t) async {
    try {
      final cp = '${(await _coversDir()).path}/${t.id}.jpg';
      await _api.downloadCover(coverUrlFor(t.id), cp);
      await _db.upsertDownloaded(DownloadedTrack(
        id: t.id,
        title: t.title,
        artist: t.artist,
        path: t.path,
        bytes: t.bytes,
        addedAt: t.addedAt,
        favorite: t.favorite,
        coverPath: cp,
      ));
    } catch (_) {
      // не нашлась — не страшно, попробуем в другой раз при следующем запуске
    }
  }

  Future<void> setFavorite(String id, bool value) async {
    await _db.setFavorite(id, value);
    await _sync?.record(value ? 'like' : 'unlike', trackId: id);
  }

  /// В избранном ли скачанный трек (для сердечка в плеере).
  Future<bool> favorite(String id) async => (await _db.downloadedById(id))?.favorite ?? false;

  Future<List<DownloadedTrack>> list({bool onlyFavorite = false}) =>
      _db.allDownloaded(onlyFavorite: onlyFavorite);

  /// [covers] — сколько из скачанных песен уже с обложкой на диске (просьба
  /// Alex 05.09.2026: видеть счётчик обложек рядом со счётчиком песен, а не
  /// гадать по логам сервера).
  Future<({int count, int bytes, int covers})> summary() async {
    final all = await _db.allDownloaded();
    final covers = all.where((t) => t.coverPath != null && File(t.coverPath!).existsSync()).length;
    return (count: all.length, bytes: await _db.totalBytes(), covers: covers);
  }

  /// Поиск по каталогу сервера (что уже скачано на домашний компьютер).
  Future<List<Map<String, dynamic>>> searchCatalog(String q) => _api.searchCatalog(q);

  /// «Докачать ещё»: спрашивает сервер, что из библиотеки ещё не скачано
  /// (избранное — вперёд), и качает порцию по budgetBytes (по умолчанию
  /// 20 ГБ). onProgress зовётся после каждого трека: (сколько скачано,
  /// сколько всего в порции, название текущего). Останавливаем скачивание
  /// без сети или другой ошибки — то, что успело, уже в «Моей музыке».
  Future<({int downloaded, int bytes, int failed})> downloadMore({
    int budgetBytes = 20 * 1024 * 1024 * 1024,
    void Function(int done, int total, String title)? onProgress,
  }) async {
    final excludeIds = (await _db.allDownloaded()).map((t) => t.id).toList();
    final batch = await _api.nextLibraryBatch(excludeIds: excludeIds, budgetBytes: budgetBytes);
    var done = 0;
    var bytes = 0;
    var failed = 0;
    for (final track in batch.tracks) {
      onProgress?.call(done, batch.tracks.length, '${track['artist'] ?? ''} — ${track['title'] ?? ''}');
      try {
        bytes += await download(track);
      } catch (_) {
        // Один плохой трек (сеть моргнула, файл пропал) не должен рвать
        // всю порцию — пробуем следующий, недокачанное подберётся в
        // следующий раз (его id не попадёт в excludeIds).
        failed++;
      }
      done++;
    }
    onProgress?.call(done, batch.tracks.length, '');
    return (downloaded: done - failed, bytes: bytes, failed: failed);
  }

  /// Заказать трек на сервере. Возвращает ответ каталога:
  /// {track_id, created, source, quality_tier}. Бросает [AcquireException].
  Future<Map<String, dynamic>> acquireOnServer({
    required String artist,
    required String title,
    int durationSec = 0,
  }) =>
      _api.acquireTrack(artist: artist, title: title, durationSec: durationSec);
}
