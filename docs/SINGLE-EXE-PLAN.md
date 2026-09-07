# SoundFlow — сервер в одном приложении (план)

Составлено 07.09.2026 (Alex TG 18716–18752). Три источника: ассистент + два
сторонних ИИ (промты давал Alex, ответы вставлял вручную). Все три сошлись.

## Зачем

Сейчас сервер = Go-бэкенд + PostgreSQL/pgvector в Docker + Python-сайдкар
(PANNs CNN14, PyTorch) на fg, запуск задачей планировщика. Alex хочет **одну
программу с окном**: запустил — видишь каталог, журнал «что сервер делает»,
устройства; без Docker и Python; переносится копированием.

## Целевая архитектура

```
                SoundFlow.exe
                     │
      ┌──────────────┼──────────────┐
   GUI (Wails)     Go API        Go workers (фоновые задачи в процессе)
      └──────────────┼──────────────┘
                     │
                 SQLite (modernc.org/sqlite, без CGo) — метаданные
                     │
              вектора: плоский файл + перебор в памяти (или sqlite-vec)
                     │
              ONNX Runtime (onnxruntime.dll) → CNN14 (cnn14.onnx)
```

На диске: `SoundFlow.exe` + `onnxruntime.dll` + `cnn14.onnx` + `soundflow.db`
(+ логи). База и логи — в `%LocalAppData%\SoundFlow\`, НЕ рядом с exe (Program
Files только на чтение).

## По компонентам

| Было | Станет | Риск | Заметки |
|---|---|---|---|
| PostgreSQL в Docker | SQLite `modernc.org/sqlite` (чистый Go) | 🟢 низкий | 9000 треков — не тот масштаб, где нужен Postgres |
| pgvector (ANN-индекс) | перебор косинуса в памяти на Go; при желании `sqlite-vec` | 🟢 низкий | 9000×2048 float32 ≈ 74 МБ; ~18 млн операций/запрос ≈ единицы мс. Наш `OrderBySimilarity` и так считает только по id, что прислал телефон |
| Python-сайдкар (PANNs, PyTorch) | модель в ONNX, вызов из Go (`yalue/onnxruntime_go`) | 🟠 средний/высокий | **главный риск всей затеи** |
| — | GUI на Wails (WebView2, HTML/CSS внутри) | 🟢 | таблицы/журнал/кнопки удобнее в вебе; WebView2 есть на Win11 и свежих Win10 |
| задача планировщика + docker | один exe + инсталлятор (Inno Setup) | 🟢/🟠 | нужен VC++ Redistributable (для onnxruntime.dll: MSVCP140/VCRUNTIME140); SmartScreen на неподписанном |

### PyTorch → ONNX — детали (это шаг 0)

- Экспорт `torch.onnx.export(..., opset_version=18)`. STFT + mel-фильтры
  torchlibrosa реализованы как веса Conv1d/Conv2d → **экспортируются вместе с
  моделью**. (Просили 17, но dynamo-экспортёр torch 2.11 не опускает `Pad` из
  STFT ниже 18; onnxruntime 1.29 opset 18 держит — разницы нет.)
- **Подготовку звука (mel-спектрограмму) оставляем ВНУТРИ ONNX-графа**
  (вариант A). НЕ переписывать STFT на Go — слишком много параметров совпадить
  точь-в-точь (окно, hop, FFT size, center, padding, mel filterbank, sample
  rate, log, нормализация, layout). Оба сторонних ИИ настояли на этом; мой
  первый поиск ошибочно склонялся к расчёту на Go.
- На вход — сырой PCM 32 кГц моно. Декодирование mp3/flac/aac в Go:
  `hajimehoshi/go-mp3` или обёртка ffmpeg; **ресемплинг в 32 кГц — тоже зона
  риска** (Go-ресемплеры дают артефакты, меняющие спектр).
- `onnxruntime_go` — НЕ чистый Go: нужен CGo + грузит `onnxruntime.dll`. Всё
  равно огромное упрощение против Docker+Python+PyTorch.
- GPU (DirectML) — НЕ в первую миграцию. Сначала CPU + корректность.

## Порядок (ничего рабочего не ломаем; Postgres не удаляем до конца)

- **Шаг 0 — валидация ONNX. ✅ СДЕЛАНО 07.09.2026 — ИДЁМ.** Песочница
  `E:\soundflow-lab\cnn14-onnx-validation\` (вне репо), venv переиспользован из
  `D:\sf-fp`. 36 файлов (24 реальных mp3 + 12 искусственных, разные sample
  rate). PyTorch vs ONNX на одном 32 кГц-сигнале: на реальной музыке cos =
  1.0 (до 10 знаков), 0 файлов ниже порога 0.9999; топ-20 соседей совпали
  36/36, ближайший #1 — 36/36. Проверка сделана на чистом Python (Go не
  ставили — по плану поднимаем на шаге 3). Ресемплер двигает отпечаток на
  ~1e-4 → на Go-стороне брать нормальный ресемплер, не линейный. Полный
  отчёт: `E:\soundflow-lab\cnn14-onnx-validation\REPORT.md`.
- **Шаг 1 — SQLite как теневая база. ✅ СДЕЛАНО 07.09.2026.**
  `apps/server/internal/localdb` (modernc.org/sqlite, без CGo): схема зеркалит
  7 таблиц Postgres, `feature_vector` → BLOB float32; `CatalogList/Search`,
  `TrackFilePath`, `OrderBySimilarity` (перебор косинуса в памяти + тот же
  разброс по артистам). Импортёр `apps/server/cmd/soundflow-import` — разовый
  Postgres→`soundflow.db`, с числом строк и XOR-FNV контрольной суммой по
  каждой таблице; `-verify` сверяет поиск и «похожие» на обеих базах.
  Прогон на soundflow2 (8781 трек, `E:\soundflow-lab\soundflow.db`, 82 МБ):
  суммы сошлись, поиск 6/6, «похожие» 80 seed-ов — 0 расхождений с pgvector.
  Старый сервер и Postgres не тронуты. Отдельных таблиц альбомов/артистов/
  плейлистов в текущей схеме нет — есть поля в `tracks` + `legacy_marks`.
- **Шаг 2 — слои. ⏸ ЧАСТИЧНО / осознанно отложено.** Полную переразбивку
  рабочего сервера на `internal/domain|db|library|...` не делали — это churn
  без видимого эффекта и с риском задеть телефонный синк. Вместо этого новый
  код лёг чистыми пакетами: `internal/localdb` (SQLite), `internal/inference`
  (ONNX), `cmd/soundflow` (окно + сервис). Старый `internal/api`/`internal/db`
  (Postgres) не тронуты. Интерфейс `Store` поверх обоих — когда понадобится.
- **Шаг 3 — новый расчёт. ✅ СДЕЛАНО 07.09.2026.** `apps/server/internal/inference`:
  `yalue/onnxruntime_go` (CGo, грузит `onnxruntime.dll` 1.29) + `cnn14.onnx`
  из шага 0. Декод — ffmpeg через stdin-pipe (юникод-пути), ресемпл soxr.
  `cmd/soundflow-fingerprint` — пересчёт в `soundflow.db`. Сверка на 36 файлах
  шага 0: raw cos Go↔PyTorch min 0.995 (разница = путь декода mp3), НО списки
  «похожих» топ-8 совпали 7.83/8 — рекомендации сохраняются. Инструменты:
  mingw-w64 16.1, onnxruntime 1.29. Полный пересчёт всех 8781 — это уже шаг 6.
- **Шаг 4 — окно на Wails. ✅ СДЕЛАНО 07.09.2026 (окно подтверждено Alex на
  рабочем столе — открывается, каталог виден).** `apps/server/cmd/soundflow`:
  один exe, окно (WebView2), каталог из `soundflow.db`, отпечаток в этом же
  процессе, без Docker/Python. `/api/*` для окна (дерево папок, поиск,
  устройства, журнал, задачи, кнопки Scan/Reindex/Stop). Телефонный API на
  SQLite: `/v1/*` (health, tracks, search, music file, cover, stream/order —
  радио, library/next-batch, sync/events, sync/report). Фронт — дашборд в
  стиле «Афиши» (дерево папок). Проверено на 8781 треке: `/api/info`,
  `/api/catalog`, `/v1/search`, `/v1/stream/order` (8719 кандидатов) —
  отдаёт. Само окно Wails проверяется запуском на рабочем столе Alex.
- **Шаг 5 — установщик. ✅ СДЕЛАНО 07.09.2026.** `apps/server/build/soundflow.iss`
  + `build.ps1`. Ставит в `%LocalAppData%\Programs\SoundFlow` без админа; тихо
  доустанавливает VC++ Redist x64 и WebView2, если нет; ярлыки. Собрано:
  `SoundFlow-Setup-0.1.0.exe` (~357 МБ, из них 323 — веса CNN14). `soundflow.db`
  в установщик не входит (данные пользователя, из `soundflow-import`).
  - **Фикс 07.09.2026:** первая сборка (портабл и установщик) падала с окном
    «Wails applications will not build without the correct build tags» —
    `build.ps1` звал `go build` без тегов. Добавлен `-tags "desktop,production"`
    (`wails.io/docs/guides/manual-builds`). Пересобрано. Проверено на brain:
    exe создаёт окно `SoundFlow` (не «Error»), отдаёт встроенный фронт и
    `/api/*` на :8090, каталог 8781. Скриншот отрисованного WebView2 не снят —
    Alex в это время работал за brain, не отбирал фокус; финально смотрит сам.
- **Шаг 6 — переключение. 🚧 В РАБОТЕ 07.09.2026 (Alex TG 18786+).**
  - **Решение Alex:** новый сервер живёт на **fg** (не на brain — вся музыка там,
    fg всегда включён). Тестировщику сборку пока не даём.
  - **Уточнение объёма 07.09 (Alex TG 18805):** Python-«сайдкар» на fg — это не
    только отпечаток, а весь движок скачивания (`soundflow-python-sidecar` v2:
    ~20 провайдеров, yt-dlp, slskd, yandex-music, playwright, curl-cffi). Порт
    на Go — месяцы и хрупко. Миграция убирает **Docker + PostgreSQL + тяжёлый ML**
    (torch/panns/librosa → ONNX в Go). Остаётся урезанный Python-качалка (без
    torch); новый exe зовёт его `/find-audio` для «Добавить музыку». Итог: без
    Docker/Postgres/PyTorch, но не «ноль Python». `/analyze-features` сайдкара
    заменяется локальным ONNX.
  - **Форм-фактор для fg — headless** (Alex TG 18794 «как твой совет»): на fg
    сервер работает фоном по расписанию, без десктоп-сессии → оконное Wails-
    приложение не поднимется. Собрана `soundflow-srv.exe` (`go build -tags
    headless -o soundflow-srv.exe ./cmd/soundflow`, 12 МБ, без WebView2). Та же
    начинка (SQLite + ONNX + телефонный API :8090 + дашборд отдаётся браузеру
    по `http://fg:8090/`). Оконный `SoundFlow.exe` остаётся для рабочего стола
    Alex и тестировщика. Проверено на brain: /v1/health, /api/info, дашборд.
  - **Что реально на fg** (посмотрел 07.09): боевой сервер — `D:\soundflow2\srv.exe`
    (Go, :8090, запуск задачей планировщика `SoundFlow2` → `run.cmd`, логи
    `srv.log`). Питон-сайдкар PANNs — служба `soundflow-sidecar` (nssm, Auto).
    Ещё: `soundflow-web` (служба), старый слой bun/TypeScript API на :8000 +
    второй Postgres (`soundflow-postgres` :5432) — не трогаем. Телефон ходит
    НЕ напрямую: WireGuard-туннель (`WireGuardTunnel$wg0`) → VDS `vdsmusic.ru`
    (nginx) → fg:8090. Сторож `soundflow-watchdog` — только шлёт Alex TG-алерты,
    сам не перезапускает; на время переключения ОТКЛЮЧИТЬ (иначе засыплет).
  - `run.cmd` даёт маппинг: `E:\soundflow-data\{cache,music}` ↔ `D:\SoundFlow\
    {cache,music}`. Для новой версии на fg: `SOUNDFLOW_AUDIO_ROOT=D:\SoundFlow`,
    `SOUNDFLOW_DB=<...>\soundflow.db`, `SOUNDFLOW_ADDR=0.0.0.0:8090`.
  - **Порт телефонного API (полный, Alex TG 18812 «по плану»):**
    - M1 ✅ `92dde77` — `internal/api`/`importer`/`acquire` на интерфейсе `Store`.
      `db.Pool` его удовлетворяет; `cmd/soundflow-server` (srv.exe) не изменился.
    - M2 ✅ `714e949` — `internal/litestore.Store`: весь набор методов (~35) на
      SQLite (обёртка над `localdb.DB` + raw SQL). `iface_test.go` стережёт.
    - M3 ✅ `dfc398a`+`de61997` — `cmd/soundflow/startPhoneServer` отдаёт
      `api.Router()` (не рукописные ручки) на `/v1/*`; `PathMap` из
      `SIDECAR_*_DIR`/`SOUNDFLOW_AUDIO_ROOT`. `Acquire` = `acquire.Service{DB:
      litestore, Finder: localFinder}`, где `localFinder` = `sidecar.Client`
      (скачивание) + ONNX (`AnalyzeFeatures` — отпечаток скачанного в процессе).
      Проверено на brain против `soundflow-new.db`: health/tracks/search/
      admin.{status,log,devices,blocklist}/trash/sync.report — форма как у
      старого srv.exe; `/v1/tracks/acquire` 502 без сайдкара (штатно);
      `/v1/admin/reanalyze` крутит ONNX-догон в процессе, без питона.
    - M4 ⏭ полная сверка ручек старый srv.exe ↔ новый на живых данных (после
      пересчёта отпечатков; `stream/order` сверять по смыслу — вектора Go≠старые).
    - M5 ⏭ на fg: слим питон-сайдкара (убрать torch/panns/librosa + youtube*.py
      + yt-dlp/bgutil из pyproject; `uv sync`), затем `fg-cutover.ps1`.
  - **Последовательность переключения (черновик, с Alex):** пересчёт готов →
    слим сайдкара → отключить `soundflow-watchdog` → стоп `SoundFlow2` + `srv.exe`
    (порт 8090) → `soundflow.db` + `soundflow-srv.exe` + ассеты в `D:\soundflow-srv`
    → задача `SoundFlowSrv` (env) → старт → Alex проверяет на ТЕЛЕФОНЕ через
    vdsmusic.ru. Откат: `fg-rollback.ps1` (вернуть `SoundFlow2`; Postgres/`srv.exe`
    не трогали).
  - **Пересчёт отпечатков (шаг 3 по всей базе):** на brain, `sffp.exe -fg
    soundflow-fg -workers 3` → `E:\soundflow-lab\soundflow-new.db`, лог
    `E:\soundflow-lab\_fgscan\refp-full.log`. 07.09 ~2000/8781, ~0.8 трек/с,
    память ровно ~1.2 ГБ, ETA ~2.5 ч. ~0.5% FAIL — файлов нет на диске fg
    (скиты, интервью, часть переименованного); список соберём в конце.

## Открытые вопросы

- ~~**Полный пересчёт отпечатков на Go** раздувает память при workers>2~~ —
  закрыто 07.09.2026. Причина была не в workers, а в ORT: CPU-арена +
  mem-pattern кэшируют буферы под каждый новый максимум длины входа и не
  освобождают (11.8 ГБ WS на 200 треках). `SetCpuMemArena(false)` +
  `SetMemPattern(false)` в `inference.Open` → память ровно ~1 ГБ на любом
  объёме. Теперь workers ограничен только скоростью scp с fg. Ещё фикс:
  `sanitize()` в `soundflow-fingerprint` резал не все спецсимволы — scp на
  Windows молча не качал файлы с апострофом в имени (~16% базы: Guns N' Roses
  и т.п.).
- ~~**Окно Wails** визуально не проверено~~ — закрыто 07.09.2026. После фикса
  тегов (см. шаг 5) Alex запустил портабл на своём рабочем столе: окно
  `SoundFlow` открывается, каталог по папкам виден. WebView2 рисует.
- **Телефонный синк на SQLite**: сделаны базовые ручки `/v1/*`, полная
  семантика (докачка/замена/обложки-догон) — не переносил, требует
  аккуратного `Store`-интерфейса поверх Postgres и SQLite. Проверить на
  реальном телефоне Alex (шаг 6).
- Wails как фоновый процесс при закрытом окне — нужен трей (не сделано).
- Длительности/битрейт в `soundflow2` пустые → в окне «0:00». Заполнять при
  скане (ffprobe) или при пересчёте.
- Подпись exe (сертификат) vs жить со SmartScreen-предупреждением.
- ~~Точный порог cosine для гейта шага 0~~ — закрыто (шаг 0).
- ~~Декодер аудио в Go + ресемплер~~ — ffmpeg+soxr через stdin-pipe (шаг 3).

## Ссылки

- sqlite-vec vs pgvector: «Postgres тебе скорее всего не нужен»
- `modernc.org/sqlite` — CGo-free SQLite для Go
- `yalue/onnxruntime_go` — обёртка ONNX Runtime для Go (Windows: грузит dll сама)
- PANNs: `qiuqiangkong/audioset_tagging_cnn`, `panns_inference`; есть
  `litert-community/PANNs-CNN14-AudioSet-LiteRT` (мобильная версия)
- Wails — Go backend + web frontend в одном desktop-приложении (WebView2)
- ONNX Runtime DirectML — «sustained engineering», MS двигается к WinML
