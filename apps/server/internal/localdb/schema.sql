-- Схема soundflow.db — лёгкая (SQLite) копия каталога для «сервера в одном exe».
-- Зеркалит те же таблицы, что PostgreSQL-схема (internal/db/migrations), с
-- поправкой на типы SQLite:
--   text[]        -> TEXT (JSON-массив)
--   timestamptz   -> TEXT (ISO-8601, как пришло из Postgres)
--   jsonb         -> TEXT
--   vector(2048)  -> BLOB (2048 float32, little-endian, 8192 байта; NULL если нет)
--   boolean       -> INTEGER 0/1
-- Пока это ТЕНЕВАЯ база: пишет в неё только одноразовый импортёр
-- (cmd/soundflow-import), рабочий сервер по-прежнему на Postgres.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS tracks (
    id             TEXT PRIMARY KEY,
    artist         TEXT NOT NULL DEFAULT '',
    title          TEXT NOT NULL DEFAULT '',
    album          TEXT NOT NULL DEFAULT '',
    year           INTEGER,
    duration_sec   INTEGER,
    language       TEXT NOT NULL DEFAULT '',
    genre_tags     TEXT NOT NULL DEFAULT '[]',
    release_kind   TEXT NOT NULL DEFAULT 'studio',
    explicit       INTEGER NOT NULL DEFAULT 0,
    is_alt_version INTEGER NOT NULL DEFAULT 0,
    cover_path     TEXT NOT NULL DEFAULT '',
    cover_ok       INTEGER NOT NULL DEFAULT 0,
    normalized_key TEXT NOT NULL DEFAULT '',
    energy         REAL,
    valence        REAL,
    feature_vector BLOB,
    waveform       BLOB,          -- N байт 0..255: рельеф громкости для полоски плеера
    cover_url      TEXT NOT NULL DEFAULT '',
    created_at     TEXT NOT NULL DEFAULT '',
    -- lower(artist||' '||title||' '||album), Unicode-aware (считает импортёр на
    -- Go): SQLite LIKE/lower() кириллицу не сворачивают, поэтому ищем по этому.
    search_text    TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS tracks_normalized_key_idx ON tracks (normalized_key);
CREATE INDEX IF NOT EXISTS tracks_artist_idx ON tracks (lower(artist));
CREATE INDEX IF NOT EXISTS tracks_search_idx ON tracks (search_text);

CREATE TABLE IF NOT EXISTS track_files (
    id             TEXT PRIMARY KEY,
    track_id       TEXT REFERENCES tracks(id) ON DELETE CASCADE,
    normalized_key TEXT NOT NULL DEFAULT '',
    file_path      TEXT NOT NULL DEFAULT '',
    mime_type      TEXT NOT NULL DEFAULT '',
    bitrate_kbps   INTEGER,
    size_bytes     INTEGER NOT NULL DEFAULT 0,
    duration_sec   INTEGER,
    source         TEXT NOT NULL DEFAULT '',
    quality_tier   TEXT NOT NULL DEFAULT 'unknown',
    loudness_lufs  REAL,
    true_peak_db   REAL,
    rejected       INTEGER NOT NULL DEFAULT 0,
    reject_reason  TEXT NOT NULL DEFAULT '',
    downloaded_at  TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS track_files_track_id_idx ON track_files (track_id);
CREATE UNIQUE INDEX IF NOT EXISTS track_files_normalized_key_uq ON track_files (normalized_key);

CREATE TABLE IF NOT EXISTS devices (
    id           TEXT PRIMARY KEY,
    name         TEXT NOT NULL DEFAULT '',
    app_version  TEXT NOT NULL DEFAULT '',
    music_bytes  INTEGER NOT NULL DEFAULT 0,
    last_sync_at TEXT,
    created_at   TEXT NOT NULL DEFAULT '',
    transport    TEXT NOT NULL DEFAULT ''   -- wifi | ethernet | mobile | vpn | ''
);

CREATE TABLE IF NOT EXISTS sync_events (
    event_uuid TEXT PRIMARY KEY,
    device_id  TEXT NOT NULL DEFAULT '',
    kind       TEXT NOT NULL DEFAULT '',
    track_id   TEXT NOT NULL DEFAULT '',
    payload    TEXT NOT NULL DEFAULT '{}',
    client_ts  INTEGER NOT NULL DEFAULT 0,
    applied_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS sync_events_device_idx ON sync_events (device_id, applied_at);

-- «Ручная синхронизация» (Alex TG 19000): комп сохраняет выбранный план,
-- телефон забирает и выполняет. Один активный план на устройство.
CREATE TABLE IF NOT EXISTS sync_plans (
    device_id  TEXT PRIMARY KEY,
    add_ids    TEXT NOT NULL DEFAULT '[]',
    remove_ids TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL DEFAULT ''
);

-- «Обучение вкусу» (docs/TASTE-PLAN.md, этап 2). Производится из sync_events
-- при каждом SaveSync: like/skip/delete/… → строка с типом и весом-концептом.
-- Храним СОБЫТИЯ, не итоговые оценки (оценки пересчитываются). event_uuid =
-- sync_events.event_uuid — дедуп.
CREATE TABLE IF NOT EXISTS feedback_event (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    event_uuid TEXT NOT NULL UNIQUE,
    device_id  TEXT NOT NULL DEFAULT '',
    track_id   TEXT NOT NULL DEFAULT '',
    artist     TEXT NOT NULL DEFAULT '',
    event_type TEXT NOT NULL DEFAULT '',   -- like/unlike/dislike/finish/skip_early/skip_normal/delete_not_my_taste/delete_bad_version/delete_dup
    value      REAL NOT NULL DEFAULT 0,    -- вес-концепт из TASTE-PLAN §1
    reason     TEXT NOT NULL DEFAULT '',
    client_ts  INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS feedback_event_track_idx ON feedback_event (track_id);
CREATE INDEX IF NOT EXISTS feedback_event_artist_idx ON feedback_event (artist);

-- «Центры вкуса» по звуку (TASTE-PLAN §3, этап 3): k-means по отпечаткам
-- положительно оценённых треков. Не один «средний вкус», а 3–5 центров —
-- у человека параллельно несколько жанров. layer — задел под слои
-- long/recent/session (пока один 'all'). Производная таблица, пересчёт по
-- запросу /api/taste/rebuild или /api/taste/cluster.
CREATE TABLE IF NOT EXISTS taste_cluster (
    layer      TEXT NOT NULL DEFAULT 'all',
    idx        INTEGER NOT NULL,
    vec        BLOB NOT NULL,               -- центроид, 2048 float32 LE, L2-нормирован
    n          INTEGER NOT NULL DEFAULT 0,  -- сколько треков в кластере
    updated_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (layer, idx)
);

CREATE TABLE IF NOT EXISTS server_log (
    id     INTEGER PRIMARY KEY,
    at     TEXT NOT NULL DEFAULT '',
    kind   TEXT NOT NULL DEFAULT '',
    artist TEXT NOT NULL DEFAULT '',
    title  TEXT NOT NULL DEFAULT '',
    detail TEXT NOT NULL DEFAULT '',
    bytes  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS server_log_at_idx ON server_log (at);

CREATE TABLE IF NOT EXISTS legacy_marks (
    normalized_key TEXT PRIMARY KEY,
    kind           TEXT NOT NULL DEFAULT '',
    artist         TEXT NOT NULL DEFAULT '',
    title          TEXT NOT NULL DEFAULT '',
    marked_at      TEXT
);

CREATE TABLE IF NOT EXISTS rejected_track_files (
    id             INTEGER PRIMARY KEY,
    normalized_key TEXT NOT NULL DEFAULT '',
    source_url     TEXT,
    provider       TEXT NOT NULL DEFAULT '',
    artist         TEXT NOT NULL DEFAULT '',
    title          TEXT NOT NULL DEFAULT '',
    reason         TEXT NOT NULL DEFAULT '',
    rejected_at    TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS rejected_track_files_uq ON rejected_track_files (normalized_key, source_url);

-- Итоги последнего импорта: число строк и контрольная сумма по каждой таблице.
-- Позволяет быстро сверить теневую базу с Postgres без повторного прохода.
CREATE TABLE IF NOT EXISTS import_meta (
    table_name TEXT PRIMARY KEY,
    row_count  INTEGER NOT NULL,
    checksum   TEXT NOT NULL,
    imported_at TEXT NOT NULL
);

-- Песни, убранные на телефоне, файлы которых на компьютере ждут подтверждения
-- в окне программы (Alex TG 19943/19948, 19.09.2026). Метка blocked уже стоит;
-- файл лежит, пока Alex не нажмёт кнопку. file_path — канонический (как в БД).
CREATE TABLE IF NOT EXISTS pending_removals (
    track_id  TEXT PRIMARY KEY,
    artist    TEXT NOT NULL DEFAULT '',
    title     TEXT NOT NULL DEFAULT '',
    file_path TEXT NOT NULL DEFAULT '',
    bytes     INTEGER NOT NULL DEFAULT 0,
    reason    TEXT NOT NULL DEFAULT '',
    added_at  TEXT NOT NULL DEFAULT ''
);
