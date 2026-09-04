import 'package:sqflite/sqflite.dart';

/// Локальная база телефона. Пока одна таблица — скачанные треки
/// (список «Моя музыка»). Дальше сюда приедут stream_buffer, trash,
/// vibe_state (см. §7 плана миграции).
class Db {
  Db._(this._db);
  final Database _db;

  static Future<Db> open({String path = 'soundflow.db', DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE downloaded_tracks (
              id        TEXT PRIMARY KEY,
              title     TEXT NOT NULL,
              artist    TEXT NOT NULL,
              path      TEXT NOT NULL,
              bytes     INTEGER NOT NULL,
              favorite  INTEGER NOT NULL DEFAULT 0,
              added_at  INTEGER NOT NULL
            )
          ''');
        },
      ),
    );
    return Db._(db);
  }

  Future<void> upsertDownloaded(DownloadedTrack t) => _db.insert(
        'downloaded_tracks',
        t.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<DownloadedTrack?> downloadedById(String id) async {
    final rows = await _db.query('downloaded_tracks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : DownloadedTrack.fromMap(rows.first);
  }

  Future<List<DownloadedTrack>> allDownloaded({bool onlyFavorite = false}) async {
    final rows = await _db.query(
      'downloaded_tracks',
      where: onlyFavorite ? 'favorite = 1' : null,
      orderBy: 'added_at DESC',
    );
    return rows.map(DownloadedTrack.fromMap).toList();
  }

  Future<int> totalBytes() async {
    final r = await _db.rawQuery('SELECT COALESCE(SUM(bytes),0) AS s FROM downloaded_tracks');
    return (r.first['s'] as int?) ?? 0;
  }

  Future<void> setFavorite(String id, bool value) => _db.update(
        'downloaded_tracks',
        {'favorite': value ? 1 : 0},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> deleteDownloaded(String id) =>
      _db.delete('downloaded_tracks', where: 'id = ?', whereArgs: [id]);

  Future<void> close() => _db.close();
}

class DownloadedTrack {
  DownloadedTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.path,
    required this.bytes,
    required this.addedAt,
    this.favorite = false,
  });

  final String id;
  final String title;
  final String artist;
  final String path;
  final int bytes;
  final bool favorite;
  final int addedAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'artist': artist,
        'path': path,
        'bytes': bytes,
        'favorite': favorite ? 1 : 0,
        'added_at': addedAt,
      };

  static DownloadedTrack fromMap(Map<String, Object?> m) => DownloadedTrack(
        id: m['id'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String,
        path: m['path'] as String,
        bytes: m['bytes'] as int,
        favorite: (m['favorite'] as int? ?? 0) == 1,
        addedAt: m['added_at'] as int,
      );
}
