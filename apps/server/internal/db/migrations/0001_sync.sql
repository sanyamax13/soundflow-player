-- Этап 3: очередь событий с телефона + реестр устройств.
-- События идемпотентны по event_uuid — сервер второй раз то же событие не примет.

CREATE TABLE IF NOT EXISTS devices (
    id           text PRIMARY KEY,
    name         text NOT NULL DEFAULT '',
    app_version  text NOT NULL DEFAULT '',
    music_bytes  bigint NOT NULL DEFAULT 0,
    last_sync_at timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sync_events (
    event_uuid text PRIMARY KEY,
    device_id  text NOT NULL REFERENCES devices(id),
    kind       text NOT NULL,          -- play | like | unlike | delete | download
    track_id   text NOT NULL DEFAULT '',
    payload    jsonb NOT NULL DEFAULT '{}'::jsonb,
    client_ts  bigint NOT NULL DEFAULT 0,  -- время события на телефоне, мс
    applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sync_events_device_idx ON sync_events (device_id, applied_at DESC);
