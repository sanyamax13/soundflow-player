import 'package:sqflite/sqflite.dart';

/// Локальная база телефона.
/// - `downloaded_tracks` — список «Моя музыка».
/// - `events_queue` — события (лайк, удаление, что слушал), копятся офлайн,
///   уходят на сервер батчем при синхронизации (этап 3 плана).
/// - `kv` — мелкие настройки (id устройства, время последней синхронизации).
/// - `removed_tracks` — журнал удалений для экрана «Убранные».
/// Дальше сюда приедут stream_buffer, vibe_state (см. §7 плана).
class Db {
  Db._(this._db);
  final Database _db;

  static Future<Db> open({String path = 'soundflow.db', DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, _) async {
          await _createDownloads(db);
          await _createSync(db);
          await _createRemoved(db);
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) await _createSync(db);
          if (from < 3) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN cover_path TEXT');
          }
          if (from < 4) await _createRemoved(db);
        },
      ),
    );
    return Db._(db);
  }

  static Future<void> _createDownloads(Database db) => db.execute('''
        CREATE TABLE downloaded_tracks (
          id         TEXT PRIMARY KEY,
          title      TEXT NOT NULL,
          artist     TEXT NOT NULL,
          path       TEXT NOT NULL,
          bytes      INTEGER NOT NULL,
          favorite   INTEGER NOT NULL DEFAULT 0,
          cover_path TEXT,
          added_at   INTEGER NOT NULL
        )
      ''');

  /// «Убранные» — что удалено из «Моей музыки»: для экрана статистики
  /// (сколько песен убрано, сколько места освободилось, по какой причине).
  /// Заменяет «Корзину» (Alex TG 18689, 07.09.2026). Локальный журнал —
  /// экран работает офлайн, без сервера.
  static Future<void> _createRemoved(Database db) => db.execute('''
        CREATE TABLE removed_tracks (
          id         TEXT PRIMARY KEY,
          title      TEXT NOT NULL,
          artist     TEXT NOT NULL,
          bytes      INTEGER NOT NULL DEFAULT 0,
          reason     TEXT NOT NULL DEFAULT '',
          removed_at INTEGER NOT NULL
        )
      ''');

  static Future<void> _createSync(Database db) async {
    await db.execute('''
      CREATE TABLE events_queue (
        uuid      TEXT PRIMARY KEY,
        kind      TEXT NOT NULL,
        track_id  TEXT NOT NULL DEFAULT '',
        payload   TEXT NOT NULL DEFAULT '{}',
        client_ts INTEGER NOT NULL,
        synced    INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
  }

  // --- Скачанные треки ---

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

  /// Поправить теги уже скачанной песни (кнопка «Исправить имя» для
  /// нечитаемых названий, Alex TG 18693).
  Future<void> updateTags(String id, {required String artist, required String title}) =>
      _db.update(
        'downloaded_tracks',
        {'artist': artist, 'title': title},
        where: 'id = ?',
        whereArgs: [id],
      );

  // --- Убранные (журнал удалений) ---

  Future<void> addRemoved({
    required String id,
    required String title,
    required String artist,
    required int bytes,
    required String reason,
    required int removedAt,
  }) =>
      _db.insert(
        'removed_tracks',
        {
          'id': id,
          'title': title,
          'artist': artist,
          'bytes': bytes,
          'reason': reason,
          'removed_at': removedAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<List<Map<String, Object?>>> removedList() => _db.query(
        'removed_tracks',
        orderBy: 'removed_at DESC',
      );

  Future<({int count, int bytes})> removedTotals() async {
    final r = await _db.rawQuery(
        'SELECT count(*) AS c, COALESCE(SUM(bytes),0) AS b FROM removed_tracks');
    return (
      count: (r.first['c'] as int?) ?? 0,
      bytes: (r.first['b'] as int?) ?? 0,
    );
  }

  /// Разбивка по причине: причина → (сколько песен, сколько байт).
  Future<Map<String, ({int count, int bytes})>> removedByReason() async {
    final rows = await _db.rawQuery(
        'SELECT reason, count(*) AS c, COALESCE(SUM(bytes),0) AS b '
        'FROM removed_tracks GROUP BY reason ORDER BY c DESC');
    return {
      for (final row in rows)
        (row['reason'] as String? ?? ''): (
          count: (row['c'] as int?) ?? 0,
          bytes: (row['b'] as int?) ?? 0,
        ),
    };
  }

  /// Убрать одну запись из журнала (после «скачать заново» или вручную).
  Future<void> removedForget(String id) =>
      _db.delete('removed_tracks', where: 'id = ?', whereArgs: [id]);

  /// Очистить журнал целиком (музыку не трогает — она и так удалена).
  Future<void> removedClear() => _db.delete('removed_tracks');

  // --- Очередь событий ---

  Future<void> enqueueEvent({
    required String uuid,
    required String kind,
    String trackId = '',
    String payload = '{}',
    required int clientTs,
  }) =>
      _db.insert(
        'events_queue',
        {
          'uuid': uuid,
          'kind': kind,
          'track_id': trackId,
          'payload': payload,
          'client_ts': clientTs,
          'synced': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

  Future<List<Map<String, Object?>>> pendingEvents({int limit = 500}) => _db.query(
        'events_queue',
        where: 'synced = 0',
        orderBy: 'client_ts ASC',
        limit: limit,
      );

  Future<int> pendingCount() async {
    final r = await _db.rawQuery('SELECT count(*) AS c FROM events_queue WHERE synced = 0');
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> markSynced(List<String> uuids) async {
    if (uuids.isEmpty) return;
    final q = List.filled(uuids.length, '?').join(',');
    await _db.rawUpdate('UPDATE events_queue SET synced = 1 WHERE uuid IN ($q)', uuids);
  }

  // --- kv ---

  Future<String?> kvGet(String k) async {
    final r = await _db.query('kv', where: 'k = ?', whereArgs: [k], limit: 1);
    return r.isEmpty ? null : r.first['v'] as String;
  }

  Future<void> kvSet(String k, String v) =>
      _db.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);

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
    this.coverPath,
  });

  final String id;
  final String title;
  final String artist;
  final String path;
  final int bytes;
  final bool favorite;
  final int addedAt;
  final String? coverPath; // локальный файл обложки на телефоне; null — нет

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'artist': artist,
        'path': path,
        'bytes': bytes,
        'favorite': favorite ? 1 : 0,
        'cover_path': coverPath,
        'added_at': addedAt,
      };

  static DownloadedTrack fromMap(Map<String, Object?> m) => DownloadedTrack(
        id: m['id'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String,
        path: m['path'] as String,
        bytes: m['bytes'] as int,
        favorite: (m['favorite'] as int? ?? 0) == 1,
        coverPath: m['cover_path'] as String?,
        addedAt: m['added_at'] as int,
      );
}
