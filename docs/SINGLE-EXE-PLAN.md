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
- **Шаг 2 — слои.** Разложить: `internal/domain`, `/db`, `/library`,
  `/recommendation`, `/audio`, `/inference`, `/jobs`, `/logging`, `/api`,
  `/desktop`. GUI зовёт сервисный слой напрямую, НЕ через localhost HTTP.
  HTTP API остаётся как доп-интерфейс для телефона. Фоновые задачи — внутрь
  Go-процесса.
- **Шаг 3 — новый расчёт.** Go + onnxruntime.dll + cnn14.onnx → вектора →
  перебор/sqlite-vec. Про существующие вектора: скопировать старые из Postgres
  как эталон И пересчитать все 9000 новым ONNX, сравнить.
- **Шаг 4 — GUI на Wails.** Дашборд: каталог (таблица), живой журнал,
  устройства, задачи, кнопки Reindex/Scan/Stop.
- **Шаг 5 — установщик.** Inno Setup. exe + dll + модель; база/логи в
  `%LocalAppData%`; тихая установка VC++ Redist x64; обработка отсутствия
  WebView2; самоподпись или инструкция про SmartScreen.
- **Шаг 6 — параллельный запуск и переключение.** Новая версия на копии базы.
  Переключение: стоп записи на пару минут → финальный экспорт Postgres →
  досинк SQLite → проверка → старт SoundFlow.exe → проверить
  воспроизведение/поиск/рекомендации. Postgres держим как откат.

## Открытые вопросы

- Точный порог cosine для гейта шага 0 — определить на реальных файлах.
- `modernc.org/sqlite/vec` (sqlite-vec без CGo) — проверить, что пакет
  существует и рабочий; иначе перебор на Go вручную.
- Wails как фоновый процесс при закрытом окне — нужен трей.
- Декодер аудио в Go + ресемплер 32 кГц — выбрать и проверить на артефакты.
- Подпись exe (сертификат) vs жить со SmartScreen-предупреждением.

## Ссылки

- sqlite-vec vs pgvector: «Postgres тебе скорее всего не нужен»
- `modernc.org/sqlite` — CGo-free SQLite для Go
- `yalue/onnxruntime_go` — обёртка ONNX Runtime для Go (Windows: грузит dll сама)
- PANNs: `qiuqiangkong/audioset_tagging_cnn`, `panns_inference`; есть
  `litert-community/PANNs-CNN14-AudioSet-LiteRT` (мобильная версия)
- Wails — Go backend + web frontend в одном desktop-приложении (WebView2)
- ONNX Runtime DirectML — «sustained engineering», MS двигается к WinML
