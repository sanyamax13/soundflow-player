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

- Экспорт `torch.onnx.export(..., opset_version=17)`. STFT + mel-фильтры
  torchlibrosa реализованы как веса Conv1d/Conv2d → **экспортируются вместе с
  моделью**.
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

- **Шаг 0 — валидация ONNX. С этого начинаем.** Отдельный маленький проект
  `cnn14-onnx-validation/` (не в SoundFlow). Экспорт CNN14 → ONNX. Прогнать
  один и тот же набор аудио через PyTorch и через Go+ONNX, сравнить:
  `max_abs_error`, `mean_abs_error`, `cosine_similarity` (порог ~>0.9999,
  уточнить эмпирически). Набор разнообразный: тихий/громкий/речь/музыка/
  короткий/длинный/моно/стерео/разные sample rate. Плюс сравнить top-20
  «похожих треков» PyTorch vs ONNX. **Гейт «идём / не идём».**
  Не прошло → сайдкар остаётся, но SQLite + GUI всё равно делаем.
- **Шаг 1 — SQLite как теневая база.** `soundflow.db`, схема. Одноразовый
  импортёр Postgres → SQLite (треки/альбомы/артисты/плейлисты/вектора +
  счётчики строк + контрольные суммы). Старый сервер работает. Новый код
  читает SQLite в режиме read-only и сверяет «похожие/vibe/поиск» с Postgres.
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
