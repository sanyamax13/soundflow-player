-- Разметка со старого плеера (этап переноса). Наполняется из вшитых в бинарь
-- JSON один раз (см. internal/legacy). Ключ — нормализованный «артист__название»
-- (quality.NormalizedKey), совпадает с tracks.normalized_key.
CREATE TABLE IF NOT EXISTS legacy_marks (
    normalized_key text PRIMARY KEY,
    kind           text NOT NULL CHECK (kind IN ('favorite', 'blocked')),
    artist         text NOT NULL DEFAULT '',
    title          text NOT NULL DEFAULT '',
    marked_at      timestamptz
);
