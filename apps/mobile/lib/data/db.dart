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
        // false — иначе sqflite кеширует инстанс по пути, а у всех тестов
        // путь один и тот же (':memory:') — «свежая» база одного теста
        // тихо переиспользует данные другого, если версия уже совпадает
        // (не доходит до onCreate/onUpgrade). Всплыло 25.09.2026 при
        // добавлении колонки energy (v7→8): три теста light_queries_test.dart
        // стали видеть чужие строки. Реальному приложению не мешает — оно
        // открывает свою единственную базу по файловому пути один раз.
        singleInstance: false,
        version: 16,
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
          if (from < 8) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN energy REAL');
          }
          // Альбом (26.09.2026, план по разбору Gemini, Alex «по твоему плану»):
          // NULL — ещё не спрашивали сервер, '' — у песни альбома нет.
          if (from < 9) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN album TEXT');
          }
          // Жанр по Яндексу (26.09.2026, фильтр радио по жанру): NULL — не спрашивали,
          // '' — сервер пока не знает (узнает фоном, спросим снова).
          if (from < 10) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN genre TEXT');
          }
          // v11 (26.09.2026) добавляла колонку lyrics — тексты песен; в тот же день Alex решил от них
          // отказаться («удали, не делай бекапов»). v12 стирает то, что успело скачаться; колонку
          // не удаляем (DROP COLUMN есть не на всех Android), она просто пустая и не используется.
          if (from >= 11 && from < 12) {
            await db.execute('UPDATE downloaded_tracks SET lyrics = NULL');
          }
          // Метка обложки с сервера (26.09.2026): поменялась — нашлась родная обложка песни
          // вместо картинки сборника (origcoverkeeper.go), перекачиваем.
          if (from < 13) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN cover_rev TEXT');
          }
          // Громкость песни в LUFS (26.09.2026, выравнивание громкости): NULL — сервер ещё не
          // посчитал (спросим снова при следующей докачке характеристик).
          if (from < 14) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN loudness REAL');
          }
          // Когда песня играла в последний раз (26.09.2026) — «забытое» в Потоке.
          if (from < 15) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN last_played INTEGER');
          }
          // Настроение по звуку с сервера (27.09.2026, moodkeeper.go): happy/sad/tender/energetic/aggressive.
          if (from < 16) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN mood TEXT');
          }
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
          duration_sec INTEGER,
          energy       REAL,
          album        TEXT,
          genre        TEXT,
          cover_rev    TEXT,
          loudness     REAL,
          last_played  INTEGER,
          mood         TEXT
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

  // Лёгкие выборки для фоновых сверок (оптимизация 21.09.2026, Alex TG 20331).
  // Раньше каждая из них грузила ВСЮ «Мою музыку» целиком (на 6000 песен — шесть
  // тысяч объектов через канал платформы) или даже все отпечатки (по 8 КБ на
  // песню, ~50 МБ), чтобы узнать одно число или список id. Единственный поток
  // базы на телефоне при этом стоял занятым, и всё остальное ждало.

  /// Сколько песен и сколько байт — одним запросом, без чтения самих строк.
  Future<({int count, int bytes})> downloadedStats() async {
    final r = await _db.rawQuery(
        'SELECT COUNT(*) AS c, COALESCE(SUM(bytes),0) AS s FROM downloaded_tracks');
    return (count: (r.first['c'] as int?) ?? 0, bytes: (r.first['s'] as int?) ?? 0);
  }

  /// id, путь к файлу и размер — без тегов и обложек.
  Future<List<({String id, String path, int bytes})>> fileRows() async {
    final rows = await _db.rawQuery('SELECT id, path, bytes FROM downloaded_tracks');
    return [
      for (final r in rows)
        (id: r['id'] as String, path: r['path'] as String, bytes: (r['bytes'] as int?) ?? 0),
    ];
  }

  /// id и путь обложки у каждой песни (путь может быть пустым).
  Future<List<({String id, String? coverPath})>> coverRows() async {
    final rows = await _db.rawQuery('SELECT id, cover_path FROM downloaded_tracks');
    return [
      for (final r in rows) (id: r['id'] as String, coverPath: r['cover_path'] as String?),
    ];
  }

  Future<List<String>> downloadedIds() async {
    final rows = await _db.rawQuery('SELECT id FROM downloaded_tracks');
    return [for (final r in rows) r['id'] as String];
  }

  /// id песен, у которых нет НИ формата, НИ битрейта, НИ длины (ждут докачки
  /// характеристик), ИЛИ нет энергии (Alex TG 25.09.2026, фильтр
  /// «Настроение») — новое поле у уже скачанных песен на старых установках
  /// пустое, даже если остальные характеристики давно пришли.
  /// [emptyMood] — ещё и песни с пустым настроением (сервер посчитал его позже, чем телефон спросил).
  /// [all] — все песни: настроение/жанр на сервере пересчитываются (6-е настроение 27.09.2026),
  /// а у песен, где всё уже заполнено, телефон иначе никогда бы их не переспросил.
  Future<List<String>> idsNeedingMeta({bool emptyMood = false, bool all = false}) async {
    if (all) {
      final rows = await _db.rawQuery('SELECT id FROM downloaded_tracks');
      return [for (final r in rows) r['id'] as String];
    }
    final rows = await _db.rawQuery('SELECT id FROM downloaded_tracks '
        "WHERE ((format IS NULL OR format = '') "
        'AND COALESCE(bitrate_kbps, 0) = 0 AND COALESCE(duration_sec, 0) = 0) '
        "OR energy IS NULL OR album IS NULL OR genre IS NULL OR genre = '' OR loudness IS NULL OR mood IS NULL"
        "${emptyMood ? " OR mood = ''" : ''}");
    return [for (final r in rows) r['id'] as String];
  }

  /// У каких песен уже есть отпечаток — только id, сами отпечатки не читаются.
  Future<Set<String>> vectorIds() async {
    final rows = await _db.rawQuery('SELECT id FROM track_vectors');
    return {for (final r in rows) r['id'] as String};
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
  /// Песня заиграла — запомнить когда (для «забытого» в Потоке).
  Future<void> markPlayed(String id) => _db.update('downloaded_tracks',
      {'last_played': DateTime.now().millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [id]);

  /// Какие песни «забыты»: не играли с [since] или ни разу.
  Future<Set<String>> forgottenIds(DateTime since) async {
    final rows = await _db.rawQuery(
        'SELECT id FROM downloaded_tracks WHERE last_played IS NULL OR last_played < ?',
        [since.millisecondsSinceEpoch]);
    return {for (final r in rows) r['id'] as String};
  }

  /// Громкость песни (LUFS) для выравнивания; null — ещё не знаем.
  Future<double?> loudnessOf(String id) async {
    final rows = await _db.rawQuery('SELECT loudness FROM downloaded_tracks WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return (rows.first['loudness'] as num?)?.toDouble();
  }

  /// Метки обложек на телефоне: id → cover_rev ('' — обычная).
  Future<Map<String, String>> coverRevs() async {
    final rows = await _db.rawQuery('SELECT id, COALESCE(cover_rev, \'\') AS r FROM downloaded_tracks');
    return {for (final r in rows) r['id'] as String: r['r'] as String};
  }

  /// Новая обложка песни: только путь и метка, остальные поля строки не трогаем.
  Future<void> setCover(String id, String path, String rev) => _db.update(
      'downloaded_tracks', {'cover_path': path, 'cover_rev': rev},
      where: 'id = ?', whereArgs: [id]);

  Future<void> updateMeta(String id,
      {int? bitrateKbps, String? format, int? durationSec, double? energy, String? album, String? genre, double? loudness,
      String? mood}) {
    final v = <String, Object?>{};
    if (mood != null && mood.isNotEmpty) v['mood'] = mood;
    if (loudness != null && loudness != 0) v['loudness'] = loudness;
    if (album != null) v['album'] = album;
    if (genre != null) v['genre'] = genre;
    if ((bitrateKbps ?? 0) > 0) v['bitrate_kbps'] = bitrateKbps;
    if ((format ?? '').isNotEmpty) v['format'] = format;
    if ((durationSec ?? 0) > 0) v['duration_sec'] = durationSec;
    if (energy != null) v['energy'] = energy;
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

  /// Кусками по [_vectorChunk] id: у SQLite на части телефонов больше 999
  /// подставляемых значений в одном запросе нельзя, а один огромный ответ
  /// (десятки МБ) держит единственный поток базы занятым.
  static const _vectorChunk = 400;

  Future<Map<String, Uint8List>> trackVectorsFor(List<String> ids) async {
    if (ids.isEmpty) return {};
    final out = <String, Uint8List>{};
    for (var i = 0; i < ids.length; i += _vectorChunk) {
      final part = ids.sublist(i, i + _vectorChunk > ids.length ? ids.length : i + _vectorChunk);
      final q = List.filled(part.length, '?').join(',');
      final rows = await _db.query('track_vectors', where: 'id IN ($q)', whereArgs: part);
      for (final r in rows) {
        out[r['id'] as String] = r['vec'] as Uint8List;
      }
    }
    return out;
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
    this.energy,
    this.album,
    this.genre,
    this.mood,
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

  /// Средняя громкость 0..1 с сервера (из waveform) — фильтр «Настроение»
  /// (Alex TG 25.09.2026). null у старых записей, пока backfillMeta не
  /// докачает.
  final double? energy;

  /// Альбом с сервера; null — ещё не узнали (backfillMeta докачает), '' — нет альбома.
  final String? album;

  /// Жанр — код Яндекса (rusrap, pop…), см. core/genres.dart; null/'' — ещё не знаем.
  final String? genre;

  /// Настроение по звуку (сервер, moodkeeper.go): happy/sad/tender/energetic/aggressive; null — не знаем.
  final String? mood;

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
        'energy': energy,
        'album': album,
        'genre': genre,
        'mood': mood,
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
        energy: (m['energy'] as num?)?.toDouble(),
        album: m['album'] as String?,
        genre: m['genre'] as String?,
        mood: m['mood'] as String?,
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
