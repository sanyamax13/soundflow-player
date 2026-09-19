import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

/// Локальная база телефона.
/// - `downloaded_tracks` — список «Моя музыка».
/// - `events_queue` — события (лайк, удаление, что слушал), копятся офлайн,
///   уходят на сервер батчем при синхронизации (этап 3 плана).
/// - `kv` — мелкие настройки (id устройства, время последней синхронизации).
/// - `removed_tracks` — старый журнал удалений; с 19.09.2026 не используется
///   (экран «Убранные» с телефона убран, Alex TG 19943). Таблица оставлена,
///   чтобы не делать миграцию.
/// Дальше сюда приедут stream_buffer, vibe_state (см. §7 плана).
class Db {
  Db._(this._db);
  final Database _db;

  static Future<Db> open({String path = 'soundflow.db', DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 7,
        onCreate: (db, _) async {
          await _createDownloads(db);
          await _createSync(db);
          await _createRemoved(db);
          await _createTrackVectors(db);
          await _createHiddenArtists(db);
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) await _createSync(db);
          if (from < 3) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN cover_path TEXT');
          }
          if (from < 4) await _createRemoved(db);
          if (from < 5) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN bitrate_kbps INTEGER');
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN format TEXT');
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN duration_sec INTEGER');
          }
          if (from < 6) await _createTrackVectors(db);
          if (from < 7) await _createHiddenArtists(db);
        },
      ),
    );
    return Db._(db);
  }

  static Future<void> _createDownloads(Database db) => db.execute('''
        CREATE TABLE downloaded_tracks (
          id           TEXT PRIMARY KEY,
          title        TEXT NOT NULL,
          artist       TEXT NOT NULL,
          path         TEXT NOT NULL,
          bytes        INTEGER NOT NULL,
          favorite     INTEGER NOT NULL DEFAULT 0,
          cover_path   TEXT,
          added_at     INTEGER NOT NULL,
          bitrate_kbps INTEGER,
          format       TEXT,
          duration_sec INTEGER
        )
      ''');

  /// Старый журнал «Убранные» (Alex TG 18689, 07.09.2026): что удалено из
  /// «Моей музыки». С 19.09.2026 не пишется и не читается — убранное знает
  /// только программа на компьютере. Таблица остаётся для старых баз.
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

  /// Звуковые отпечатки уже скачанных песен — для офлайн-радио, когда
  /// сервер недоступен. ОТДЕЛЬНАЯ таблица, не колонка в downloaded_tracks:
  /// downloaded_tracks читается целиком в автосинке каждые 3 минуты и в
  /// списке «Моя музыка» — колонка на 8 КБ раздула бы эти чтения, а
  /// INSERT OR REPLACE при повторной докачке (redownload/_fetchCoverFor)
  /// затирал бы значение, если явно не перечислить его в каждом апдейте.
  static Future<void> _createTrackVectors(Database db) => db.execute('''
        CREATE TABLE IF NOT EXISTS track_vectors (
          id  TEXT PRIMARY KEY,
          vec BLOB NOT NULL
        )
      ''');

  /// «Скрыть исполнителя» (долгое нажатие в плеере) раньше только слало
  /// событие на сервер — на самом телефоне нигде не запоминалось, поэтому
  /// Поток продолжал играть скрытого исполнителя как ни в чём не бывало
  /// (Опус-ревью телефона 14.09.2026, пункт 6). Своя таблица — фильтруем
  /// локально, без сети.
  static Future<void> _createHiddenArtists(Database db) => db.execute('''
        CREATE TABLE IF NOT EXISTS hidden_artists (
          artist    TEXT PRIMARY KEY,
          hidden_at INTEGER NOT NULL
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

  /// Полный сброс — «как первый раз установил» (Alex TG 15.09.2026): чистит
  /// всю музыку/историю на телефоне. Специально НЕ трогает kv-ключи
  /// server_url/device_id — иначе на сервере появится ещё одна запись
  /// устройства-«призрака» (та самая проблема с дублями, что чинили в
  /// этом же разговоре). Файлы на диске удаляет вызывающий (DownloadsRepo) —
  /// здесь только база.
  Future<void> fullReset() async {
    final b = _db.batch();
    b.delete('downloaded_tracks');
    b.delete('removed_tracks');
    b.delete('track_vectors');
    b.delete('hidden_artists');
    b.delete('events_queue');
    b.delete('kv', where: 'k NOT IN (?, ?)', whereArgs: ['server_url', 'device_id']);
    await b.commit(noResult: true);
  }

  /// Поправить теги уже скачанной песни (кнопка «Исправить имя» для
  /// нечитаемых названий, Alex TG 18693).
  Future<void> updateTags(String id, {required String artist, required String title}) =>
      _db.update(
        'downloaded_tracks',
        {'artist': artist, 'title': title},
        where: 'id = ?',
        whereArgs: [id],
      );

  /// Дописать характеристики файла (пришли с сервера позже) — только
  /// непустые значения, чтобы не затирать уже известное.
  Future<void> updateMeta(String id,
      {int? bitrateKbps, String? format, int? durationSec}) {
    final v = <String, Object?>{};
    if ((bitrateKbps ?? 0) > 0) v['bitrate_kbps'] = bitrateKbps;
    if ((format ?? '').isNotEmpty) v['format'] = format;
    if ((durationSec ?? 0) > 0) v['duration_sec'] = durationSec;
    if (v.isEmpty) return Future.value();
    return _db.update('downloaded_tracks', v, where: 'id = ?', whereArgs: [id]);
  }

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

  // --- Отпечатки треков (офлайн-радио) ---

  Future<void> setTrackVector(String id, Uint8List vec) => _db.insert(
        'track_vectors',
        {'id': id, 'vec': vec},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<Uint8List?> trackVector(String id) async {
    final rows = await _db.query('track_vectors', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first['vec'] as Uint8List;
  }

  Future<Map<String, Uint8List>> trackVectorsFor(List<String> ids) async {
    if (ids.isEmpty) return {};
    final q = List.filled(ids.length, '?').join(',');
    final rows = await _db.query('track_vectors', where: 'id IN ($q)', whereArgs: ids);
    return {
      for (final r in rows) r['id'] as String: r['vec'] as Uint8List,
    };
  }

  // --- Скрытые исполнители (Поток) ---

  Future<void> hideArtist(String artist) => _db.insert(
        'hidden_artists',
        {'artist': artist, 'hidden_at': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> unhideArtist(String artist) =>
      _db.delete('hidden_artists', where: 'artist = ?', whereArgs: [artist]);

  Future<Set<String>> hiddenArtists() async {
    final rows = await _db.query('hidden_artists');
    return {for (final r in rows) r['artist'] as String};
  }

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
    this.bitrateKbps,
    this.format,
    this.durationSec,
  });

  final String id;
  final String title;
  final String artist;
  final String path;
  final int bytes;
  final bool favorite;
  final int addedAt;
  final String? coverPath; // локальный файл обложки на телефоне; null — нет

  /// Характеристики файла — приходят с сервера (там считаются при скачивании).
  /// null у старых записей, пока фоновая докачка (backfillMeta) не заполнит.
  final int? bitrateKbps;
  final String? format; // MP3 / FLAC / M4A / OGG …
  final int? durationSec;

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'artist': artist,
        'path': path,
        'bytes': bytes,
        'favorite': favorite ? 1 : 0,
        'cover_path': coverPath,
        'added_at': addedAt,
        'bitrate_kbps': bitrateKbps,
        'format': format,
        'duration_sec': durationSec,
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
        bitrateKbps: m['bitrate_kbps'] as int?,
        format: m['format'] as String?,
        durationSec: m['duration_sec'] as int?,
      );

  /// Короткая строка характеристик: «320k · MP3 · 3:45» (пустые части
  /// пропускаются). Вес добавляется отдельно на экране.
  String get specs {
    final parts = <String>[];
    if ((bitrateKbps ?? 0) > 0) parts.add('${bitrateKbps}k');
    if ((format ?? '').isNotEmpty) parts.add(format!);
    final d = durationSec ?? 0;
    if (d > 0) parts.add('${d ~/ 60}:${(d % 60).toString().padLeft(2, '0')}');
    return parts.join(' · ');
  }
}

/// MP3 / FLAC / … из mime-типа сервера («audio/mpeg» → «MP3»).
String? formatFromMime(String? mime) {
  switch ((mime ?? '').toLowerCase()) {
    case 'audio/mpeg':
    case 'audio/mp3':
      return 'MP3';
    case 'audio/flac':
    case 'audio/x-flac':
      return 'FLAC';
    case 'audio/mp4':
    case 'audio/aac':
    case 'audio/x-m4a':
      return 'M4A';
    case 'audio/ogg':
    case 'audio/opus':
      return 'OGG';
    case 'audio/wav':
    case 'audio/x-wav':
      return 'WAV';
    case '':
      return null;
    default:
      return (mime ?? '').split('/').last.toUpperCase();
  }
}
