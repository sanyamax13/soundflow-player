-- Этап 5: схема каталога (пока пустая — наполнится, когда сервер научится
-- искать и качать музыку). Поля качества/версий — под правила из
-- internal/quality: release_kind, explicit, quality_tier, rejected и т.д.

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS tracks (
    id             text PRIMARY KEY,
    artist         text NOT NULL,
    title          text NOT NULL,
    album          text NOT NULL DEFAULT '',
    year           int,
    duration_sec   int,
    language       text NOT NULL DEFAULT '',
    genre_tags     text[] NOT NULL DEFAULT '{}',
    release_kind   text NOT NULL DEFAULT 'studio',  -- studio|single|remaster|remix|acoustic|live|instrumental|cover|demo
    explicit       boolean NOT NULL DEFAULT false,
    is_alt_version boolean NOT NULL DEFAULT false,   -- кавер/ремикс/версия — в общий поток не суём
    cover_path     text NOT NULL DEFAULT '',
    cover_ok       boolean NOT NULL DEFAULT false,   -- обложка ≥600 px
    normalized_key text NOT NULL DEFAULT '',
    energy         real,
    valence        real,
    feature_vector vector(2048),                     -- эмбеддинг по звуку, заполнится позже
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tracks_normalized_key_idx ON tracks (normalized_key);
CREATE INDEX IF NOT EXISTS tracks_artist_idx ON tracks (lower(artist));

CREATE TABLE IF NOT EXISTS track_files (
    id             text PRIMARY KEY,
    track_id       text REFERENCES tracks(id) ON DELETE CASCADE,
    normalized_key text NOT NULL,
    file_path      text NOT NULL,
    mime_type      text NOT NULL DEFAULT '',
    bitrate_kbps   int,
    size_bytes     bigint NOT NULL DEFAULT 0,
    duration_sec   int,
    source         text NOT NULL DEFAULT '',         -- yandex | rutracker_album | ...
    quality_tier   text NOT NULL DEFAULT 'unknown',  -- bad|acceptable|good|excellent|unknown
    loudness_lufs  real,
    true_peak_db   real,
    rejected       boolean NOT NULL DEFAULT false,   -- «плохая версия» — не возвращаться к источнику
    reject_reason  text NOT NULL DEFAULT '',
    downloaded_at  timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS track_files_normalized_key_uq ON track_files (normalized_key);

-- Отпечатки отклонённых источников: при повторном поиске того же normalized_key
-- провайдеры пропускают эти URL.
CREATE TABLE IF NOT EXISTS rejected_track_files (
    id               bigserial PRIMARY KEY,
    normalized_key   text NOT NULL,
    source_url       text,
    provider         text NOT NULL DEFAULT '',
    artist           text NOT NULL DEFAULT '',
    title            text NOT NULL DEFAULT '',
    reason           text NOT NULL DEFAULT '',
    rejected_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (normalized_key, source_url)
);
