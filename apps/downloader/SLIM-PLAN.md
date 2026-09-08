# apps/downloader — качалка «найти и скачать» для окна SoundFlow

Снято с фг (`D:\soundflow-app\apps\python-sidecar`, v2.0.0a0) 08.09.2026,
пока фг жив. Это тонкий Python-сервис за интерфейсом Go (`internal/sidecar`,
`internal/acquire.Finder`). Курс «убрать fg» — качалка переезжает на brain
рядом с `SoundFlow.exe`.

## Решение по архитектуре (Alex TG 18937–18957 + 2 сторонних ИИ 18949–18952)

- Python НЕ переписывать на Go сейчас. Держать дочерним процессом, которым
  владеет Go: запуск скрытый, свободный порт, `/health` ждём, гасим на
  выходе, перезапуск при падении.
- Общение — HTTP на 127.0.0.1 (контракт `internal/sidecar` уже есть),
  порт случайный свободный (не фикс 8001).
- Упаковка позже: сначала работает из `uv`-венва, потом PyInstaller
  **onedir** (не one-file: медленный старт + ложные срабатывания антивируса).
- **Два режима в окне (Alex 18958, голос — торренты должны быть видимыми,
  не «скрытно качается»):**
  1. **«Найти трек»** — быстрый автомат для ОДНОГО трека: артист+название →
     цепочка Яндекс → musify → mp3party, берёт лучшую версию, качает.
     Тут выбора нет — это `/find-audio` как есть (Яндекс = точная студийная
     320). Торренты из этой цепочки УБРАТЬ.
  2. **«Торренты — обзор»** — руками: артист/альбом → опрос nnmclub/rutor/
     tapochek → СПИСОК кандидатов (альбом, год, формат/битрейт, размер,
     сиды/личи, трекер) БЕЗ скачивания → Alex ставит галочку → скачиваем
     выбранный альбом, треки в каталог.
     Нужны НОВЫЕ ручки: `POST /torrent/search` (только поиск, вернуть
     кандидатов) и `POST /torrent/download` (по выбранному forum_url/magnet).
     `*_album.py` на фг уже разделены на search + download внутри —
     расщепить наружу.
- Soulseek, SoundCloud, YouTube — потом.
- Торренты: qBittorrent на brain УЖЕ установлен (`C:\Program Files\
  qBittorrent\qbittorrent.exe`), выключен. SoundFlow поднимает и его.
- Токены есть (сняты с фг вместе с качалкой): `YANDEX_MUSIC_TOKEN`,
  `QBT_*`, `RUTRACKER_COOKIE`, `NNMCLUB_COOKIE`, `TAPOCHEK_USER/PASS` —
  в `E:\soundflow-lab\fg-sidecar-src\.env` (НЕ в git). Позже → в
  `%LocalAppData%\SoundFlow\downloader.env`.

## Что вырезать (slim)

Удалить провайдеры:
`youtube.py`, `youtube_music_download.py`, `soundcloud.py`,
`soundcloud_download.py`, `soulseek.py`, `soulseek_download.py`,
`rutube.py`, `audio_features.py`, `loudness.py`.
Тесты под них: `tests/test_soulseek.py`, `test_soundcloud.py`,
`test_youtube.py`, `test_rutube.py`.

`src/main.py`:
- убрать `import yt_dlp` (верх файла);
- убрать роуты `/analyze-features`, `/analyze-loudness`, `/umap-projection`,
  `/soulseek/find-and-download`, `/search`, `/resolve`, `/import-playlist`,
  `/import-url`;
- оставить `/health`, `/find-audio`, `/id3-info`, `/yandex/search-artist`,
  `/yandex/track-cover`, `/musify-find`, `/musify-download`.

`src/providers/audio_chain.py` (режим 1 «Найти трек»):
- убрать импорты `soundcloud_download`, `youtube_music_download`,
  `soulseek_download`; убрать весь `fast_tasks`/`_await_fast_results`/
  `_cancel_and_cleanup_fast` блок;
- убрать торренты из этой цепочки (они теперь режим 2, руками);
- порядок: yandex → musify → mp3party;
- mp3party сейчас отключён (комментарий «в РФ 29-байтовые stubs») —
  вернуть как последний, но не падать если пусто.

Режим 2 «Торренты — обзор» — новый модуль `src/providers/torrent_browse.py`
(или расширить `main.py`): `search(query)` опрашивает nnmclub/rutor/
tapochek, объединяет кандидатов `{tracker, forum_url, album, year, format,
bitrate_kbps, size_bytes, seeders, leechers}`; `download(forum_url|magnet)`
= существующая download-половина `*_album.py`. Ручки `/torrent/search`,
`/torrent/download`.

`pyproject.toml` — выкинуть зависимости:
`yt-dlp`, `bgutil-ytdlp-pot-provider`, `slskd-api`, `torch`, `torchaudio`,
`panns-inference`, `librosa`.
Оставить: `fastapi`, `uvicorn[standard]`, `httpx`, `mutagen`,
`python-dotenv`, `qbittorrent-api`, `yandex-music`, `beautifulsoup4`,
`curl-cffi>=0.14,<0.15`, `playwright` (проверить, нужен ли musify
Cloudflare — если нет, тоже убрать).

`chart_routes.py` + `parsers/` — оставить (нужны item 4 «автоподбор»),
проверить что тянут только `yandex-music`/`httpx`/`bs4`.

## Wiring (Go)

1. `cmd/soundflow/downloader.go` (новый): менеджер дочернего процесса —
   свободный порт, `exec` скрыто (`SysProcAttr HideWindow`), env
   `SIDECAR_PORT` + `SIDECAR_HOST=127.0.0.1` + путь к `downloader.env`,
   ждём `GET /health`, `context` на выход, рестарт при падении.
2. `startPhoneServer`: после старта качалки — `apiSrv.Acquire =
   &acquire.Service{DB: store, Finder: &localFinder{Client: sidecar.New(
   "http://127.0.0.1:<порт>")...}}` (сейчас включается только если
   `cfg.SidecarURL != ""`).
3. qBittorrent: тот же менеджер поднимает `qbittorrent.exe` (проверить
   `--webui-port`, save-path = `E:\soundflow-data\music`), либо документируем
   ручной запуск.
4. Окно: раздел «Найти и скачать» — поля артист+название, `POST /api/acquire`
   → `apiSrv.Acquire.Acquire`, результат в «Задачи».

## Упаковка (после того как заработает)

PyInstaller onedir → `apps/server/build/dist/app/downloader/`. Скрытые
импорты: `curl_cffi`, `yandex_music`, `uvicorn` loops. Плюс qBittorrent
в установщик (или требовать установку). `.env` — не в сборку, генерим
шаблон при первом запуске в `%LocalAppData%\SoundFlow\`.
