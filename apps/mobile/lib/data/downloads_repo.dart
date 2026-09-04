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
    await _db.upsertDownloaded(DownloadedTrack(
      id: id,
      title: '${track['title'] ?? id}',
      artist: '${track['artist'] ?? ''}',
      path: path,
      bytes: size,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await _sync?.record('download', trackId: id);
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

  Future<List<DownloadedTrack>> list({bool onlyFavorite = false}) =>
      _db.allDownloaded(onlyFavorite: onlyFavorite);

  Future<({int count, int bytes})> summary() async {
    final all = await _db.allDownloaded();
    return (count: all.length, bytes: await _db.totalBytes());
  }

  /// Что предлагает сервер (пока — тестовый список; каталога ещё нет).
  Future<List<Map<String, dynamic>>> serverTracks() => _api.tracks();
}
