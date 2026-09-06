-- Лента действий сервера для экрана «Сервер» (Alex 06.09.2026, разбор
-- плеера п.10 и 12). Что сервер сделал сам, человеческим текстом:
-- добавил трек, убрал, не нашёл, заменил на версию получше, ошибка.
-- Освобождённое место считаем как сумму bytes у строк kind='removed'.
-- Телефон читает сводку через /v1/admin/status, ленту — через /v1/admin/log.
CREATE TABLE IF NOT EXISTS server_log (
    id     bigserial PRIMARY KEY,
    at     timestamptz NOT NULL DEFAULT now(),
    kind   text NOT NULL,          -- added | removed | not_found | replaced | error | info
    artist text NOT NULL DEFAULT '',
    title  text NOT NULL DEFAULT '',
    detail text NOT NULL DEFAULT '',
    bytes  bigint NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS server_log_at_idx ON server_log (at DESC);
