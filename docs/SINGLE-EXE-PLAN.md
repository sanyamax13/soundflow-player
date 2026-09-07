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
- **Шаг 4 — окно на Wails. ✅ СДЕЛАНО 07.09.2026.** `apps/server/cmd/soundflow`:
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
- **Шаг 6 — параллельный запуск и переключение. ⏭ НЕ НАЧАТ — нужен Alex.**
  Новая версия на копии базы. Переключение: стоп записи на пару минут →
  финальный экспорт Postgres (`soundflow-import`) → досинк SQLite → проверка →
  старт `SoundFlow.exe` → проверить на ТЕЛЕФОНЕ Alex: воспроизведение, поиск,
  рекомендации, докачка. Postgres держим как откат. Плюс полный пересчёт
  отпечатков на Go (шаг 3) по всей базе с проверкой памяти (batch течёт при
  workers>2).

## Открытые вопросы

- **Полный пересчёт отпечатков на Go** по всей базе: `soundflow-fingerprint`
  на `workers>2` раздувает память (промежуточные тензоры STFT на длинных
  треках). Гонять `-workers 1..2` или считать чанками. Делать в шаге 6.
- **Окно Wails**: после фикса тегов (см. шаг 5) exe на brain создаёт окно
  `SoundFlow` с валидным хэндлом и отдаёт свой встроенный фронт — окно
  открывается. Пиксельная отрисовка WebView2 глазами/скриншотом ещё не
  подтверждена (Alex работал за машиной) — финальную проверку делает Alex
  на рабочем столе.
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
