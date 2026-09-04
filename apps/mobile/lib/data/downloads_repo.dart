import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'db.dart';

/// Скачивание треков с сервера в память телефона и учёт скачанного —
/// список «Моя музыка». Правила 50 ГБ, автоподкачка по Wi-Fi — потом.
class DownloadsRepo {
  DownloadsRepo(this._api, this._db);

  final Api _api;
  final Db _db;

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
    return size;
  }

  Future<void> delete(String id) async {
    final row = await _db.downloadedById(id);
    if (row != null) {
      final f = File(row.path);
      if (f.existsSync()) f.deleteSync();
    }
    await _db.deleteDownloaded(id);
  }

  Future<void> setFavorite(String id, bool value) => _db.setFavorite(id, value);

  Future<List<DownloadedTrack>> list({bool onlyFavorite = false}) =>
      _db.allDownloaded(onlyFavorite: onlyFavorite);

  Future<({int count, int bytes})> summary() async {
    final all = await _db.allDownloaded();
    return (count: all.length, bytes: await _db.totalBytes());
  }

  /// Что предлагает сервер (пока — тестовый список; каталога ещё нет).
  Future<List<Map<String, dynamic>>> serverTracks() => _api.tracks();
}
