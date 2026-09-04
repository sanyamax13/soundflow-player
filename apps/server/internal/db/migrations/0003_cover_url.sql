-- Этап 8: URL обложки трека (сервер скачает картинку позже; пока храним ссылку).
ALTER TABLE tracks ADD COLUMN IF NOT EXISTS cover_url text NOT NULL DEFAULT '';
