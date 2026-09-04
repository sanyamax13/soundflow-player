import 'dart:io';

import 'package:path_provider/path_provider.dart';

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

  Future<void> delete(String id) async {
    final row = await _db.downloadedById(id);
    if (row != null) {
      final f = File(row.path);
      if (f.existsSync()) f.deleteSync();
    }
    await _db.deleteDownloaded(id);
    await _sync?.record('delete', trackId: id);
  }

  Future<void> setFavorite(String id, bool value) async {
    await _db.setFavorite(id, value);
    await _sync?.record(value ? 'like' : 'unlike', trackId: id);
  }

  /// В избранном ли скачанный трек (для сердечка в плеере).
  Future<bool> favorite(String id) async => (await _db.downloadedById(id))?.favorite ?? false;

  Future<List<DownloadedTrack>> list({bool onlyFavorite = false}) =>
      _db.allDownloaded(onlyFavorite: onlyFavorite);

  Future<({int count, int bytes})> summary() async {
    final all = await _db.allDownloaded();
    return (count: all.length, bytes: await _db.totalBytes());
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
