# Вкус в три слоя + офлайн-радио — дизайн

Дата: 13.09.2026. Статус: одобрено Alex-ом (общая идея — «Да делаем.» 12.09,
первая версия дизайна — 13.09; после разбора вторым мнением (Опус) — «делай
то что предложил опус», см. ниже раздел «Правки по второму мнению»).

## 0. Зачем

Сейчас профиль вкуса — один плоский слой `taste_cluster(layer='all')`
(`internal/localdb/taste_cluster.go`), пересчитывается только руками
(`POST /api/taste/rebuild` / `/api/taste/cluster`). `OrderRadio`
(`internal/localdb/radio.go:88`) подмешивает его как `sc := sim + 0.15*aff` —
вкус лёгкая добавка поверх звукового сходства с seed-песней.

`TASTE-PLAN.md` §3 давно описывает три слоя (`long_term` / `recent` /
`session`, веса 0.60/0.25/0.15) — сейчас реализован только `long_term`, и то
без автопересчёта.

Отдельная, более острая проблема с автономностью: `_radio()`
(`features/player/player_view.dart:294-332`) при сбое сети просто показывает
тост «Сервер не ответил — радио не собралось». Без сервера кнопка «Радио»
не работает вообще, даже среди уже скачанных песен. Alex явно попросил
автономность: «нет доступа к серверу и приложение не работает как я хочу».

## 1. Общая идея

Сервер продолжает считать всё (он один видит весь каталог и всю историю
сигналов). Дополнительно:

- профиль вкуса раскладывается на три слоя вместо одного;
- сервер отдаёт телефону: (а) маленький слепок центров вкуса — редко, только
  когда реально изменился; (б) «отпечаток» каждой скачанной песни — по
  запросу сразу после скачивания, отдельно от списков треков;
- на телефоне копится своя мини-база отпечатков уже скачанных песен;
- если сервер недоступен, радио не отваливается с ошибкой — телефон сам
  сравнивает уже скачанные песни по отпечаткам и вкусу, и раскладывает
  очередь на глаз похоже (без слоя «прямо сейчас», без штрафов за скипы —
  этого сервер не давал офлайн, но правило «не больше 2 подряд одного
  исполнителя» — да, это чисто локальные данные).
- офлайн-радио не ищет новую музыку — только переставляет то, что уже
  скачано.

## 2. Правки по второму мнению (обязательные)

Первая версия дизайна (что уже отправлено Alex-у в чат 13.09) содержала
пять ошибок, найденных при проверке кода вторым мнением (Опус, полный текст
проверки — в истории сессии). Ниже — как исправлено. Дальнейшие разделы
спека уже написаны с учётом исправлений.

1. **Формула весов** — было предложено `sc := sim + 0.60·affLong +
   0.25·affRecent + 0.15·affSession` (вклад вкуса до 100%). Это меняет смысл
   радио: сейчас вкус — тайбрейкер (≤0.15), «Радио по этой песне» следует
   именно ЗА песней. Правильно: слои вкуса складываются МЕЖДУ СОБОЙ в единую
   `aff` (0.60/0.25/0.15, сумма = 1 — как и было задумано в TASTE-PLAN §3),
   а сама `aff` подставляется в прежнюю формулу без изменений:
   `sc := sim + 0.15*aff`. Штрафы за нелюбимых артистов, антипузырь
   (`aff < 0.4`) — не трогаем, они откалиброваны под старую шкалу `aff`.
2. **Отпечатки НЕ в списках треков.** Было предложено класть
   `feature_vector` в JSON каждого трека везде, где сервер отдаёт список
   (каталог, докачка, поиск). У Alex каталог — тысячи треков, разовый список
   разросся бы на десятки МБ и подвесил бы разбор JSON на телефоне.
   Исправлено: отдельная ручка, телефон дёргает её сам сразу после
   скачивания конкретного файла (см. §4.3).
3. **Бэкфилл старых скачиваний — не опция, а условие работы.** На телефоне
   уже ~37 ГБ скачанного без отпечатков. Без разовой тихой докачки
   отпечатков для того, что уже лежит, офлайн-радио никогда не сработает
   на практике (не наберётся кандидатов). Добавлен явный шаг бэкфилла,
   по образцу уже существующих `backfillCovers()`/`backfillMeta()`.
4. **Отдельная таблица на телефоне, не колонка.** Колонка `feature_vector` в
   `downloaded_tracks` означала бы: (а) `SELECT *` из этой таблицы (вызывается
   из автосинка каждые 3 минуты, из списка «Моя музыка» и т.д.) тянул бы
   лишние десятки МБ в память при каждом обращении; (б)
   `ConflictAlgorithm.replace` при обновлении обложки/повторной докачке стирал
   бы значение поля, если его не перечислить явно. Исправлено: отдельная
   таблица `track_vectors(id TEXT PRIMARY KEY, vec BLOB)`.
5. **Слепок вкуса — не в каждой синхронизации.** Синк идёт часто (каждые
   3 минуты, плюс после событий) — если центроиды слать каждый раз, за час
   набегут лишние мегабайты, хотя между синками они почти всегда одни и те
   же. Исправлено: отдаём только версию/хэш центроидов при каждом синке (это
   несколько байт), сами центроиды — отдельной ручкой, только когда хэш
   разошёлся с тем, что телефон уже сохранил.

Остальные находки второго мнения (мельче) учтены как явные решения в
разделах §3-§6 ниже (окно 'recent' по протухшим данным, порог минимального
числа треков на слой, по какому времени считать 'session', детерминизм
пересчёта центров, гонки при автопересчёте, типы данных на телефоне) —
чтобы не остаться молчаливыми умолчаниями.

## 3. Сервер (Go) — три слоя вкуса

### 3.1 Схема

`taste_cluster` уже готова (`PRIMARY KEY(layer, idx)`) — просто используем
разные значения `layer`: `'long_term'` и `'recent'` вместо `'all'`. Разовая
миграция при старте: `DELETE FROM taste_cluster WHERE layer = 'all'` (это
derived-кэш, не пользовательские данные — пересоберётся сам).

`'session'` НЕ хранится в таблице — считается на лету при каждом запросе
радио (см. §3.4), слишком мало данных для k-means и должен реагировать
мгновенно, а не по расписанию пересчёта.

### 3.2 RecomputeTasteClusters(layer, since *time.Time)

Меняем сигнатуру `RecomputeTasteClusters()` → `RecomputeTasteClusters(layer
string, since *time.Time) (nClusters, nTracks int, err error)`:

- `layer="long_term", since=nil` — как сейчас, весь позитивный фидбек
  (`posScoredWithVector`, без доп. условия по времени).
- `layer="recent", since=&cutoff` (cutoff = now − 21 день) — тот же запрос
  плюс `AND fe.max_created_at >= ?` (нужно завести подзапрос
  `MAX(created_at)` рядом с `SUM(value)` в `posScoredWithVector`, т.к. окно
  режет по свежести сигнала, не по сумме).
- **Порог минимума:** если после фильтра `len(vecs) < 8`, слой не строится —
  `DELETE FROM taste_cluster WHERE layer = ?` и выход с `nClusters=0` (иначе
  k-means на 2-7 треках при `kFor()==3` даёт вырожденные «центр = одна
  конкретная песня», см. `kmeans.go:119` — пустой кластер пересеивается
  случайным вектором из входных).
- `posScoredWithVector` получает `ORDER BY t.id` — без него порядок строк
  из SQLite не гарантирован, а первый центр k-means берётся как
  `vecs[rng.Intn(n)]` при фиксированном seed 42: без стабильного порядка
  входа центры будут прыгать от пересчёта к пересчёту даже без изменений
  данных. Это сейчас незаметно (пересчёт только руками), станет заметно
  после автопересчёта (§3.5).

`/api/taste/rebuild` и `/api/taste/cluster` (`cmd/soundflow/taste.go`)
зовут теперь оба слоя: `RecomputeTasteClusters("long_term", nil)` и
`RecomputeTasteClusters("recent", &cutoff)` подряд, суммируют счётчики в
ответе. Существующий контракт ответа (JSON с `clusters`/`tracks`) не рвём —
добавляем разбивку по слоям как доп. поля, не убирая старые.

Окно `TasteClusters(perCluster)` для вкладки «Вкус» на компьютере — по
`long_term` (как сейчас, самый содержательный слой для обзора вручную);
`recent` показываем там же отдельным блоком, если он есть.

### 3.3 session — на лету, без хранения

Новая функция `sessionAffinity() (vecs [][]float32, ok bool)` — БЕЗ
параметра `deviceID`: `OrderRadio`/`OrderBySimilarity` сейчас не принимают
device id вообще (сигнатура `api.Store.OrderBySimilarity(ctx, seedID,
candidateIDs)` — заводить deviceID означало бы менять этот интерфейс и
снова упираться в `internal/db` §3.6). У Alex один основной телефон,
глобальный «последний лайк» не хуже per-device на практике — если станет
нужен per-device, это отдельная небольшая доработка потом:

- берёт последние ≤5 событий из `feedback_event` с `event_type='like'`
  (только явный лайк — НЕ `finish`: `finish` срабатывает на каждой
  доигранной в радио песне, а радио само же их и поставило — если считать
  сессию по `finish`, она бетонирует собственный выбор радио, замкнутый
  круг);
- фильтр по свежести — `client_ts >= now - 2h` (взять `client_ts`, НЕ
  `created_at`: `created_at` — время применения на сервере; если телефон
  был без сети 3 дня, весь накопленный батч ляжет с `created_at ≈ сейчас`,
  и три дня прослушивания разом стали бы «текущей сессией». Защита от
  кривых часов телефона: игнорировать события с `client_ts` из будущего
  или старше суток относительно `created_at` того же события);
- не усредняем векторы (TASTE-PLAN §3 п.4: «не один центр, средне — каша») —
  берём максимум косинуса к любому из последних ≤5 лайкнутых треков, как и
  везде в проекте («ближайший, не средний»);
- нет ни одного подходящего события → `ok=false`, вклад session = 0.

`sessionAffinity` не привязан к устройству курсором на UI (окно «Вкус» на
компьютере его не показывает — это исключительно серверный служебный сигнал
для формулы радио, скрытый от глаз).

### 3.4 OrderRadio — правка одной строки

`internal/localdb/radio.go:36-40,86-88`:

```go
centsLong, err := d.tasteCentroidsLayer("long_term")
...
centsRecent, err := d.tasteCentroidsLayer("recent")
...
// нет ни long_term центров — ведём себя как раньше (OrderBySimilarity)
if len(seedVec) == 0 || len(centsLong) == 0 || len(candidateIDs) == 0 {
    return d.OrderBySimilarity(seedID, candidateIDs)
}
```

и в цикле кандидатов:

```go
affLong := tasteAffinity(centsLong, v)
affRecent := tasteAffinity(centsRecent, v)     // centsRecent может быть пустым → 0
affSession := 0.0
if sessVecs, ok := d.sessionAffinity(); ok {  // считается один раз до цикла кандидатов
    affSession = tasteAffinity(sessVecs, v)
}
aff := 0.60*affLong + 0.25*affRecent + 0.15*affSession
sc := sim + 0.15*aff   // как раньше — только aff теперь трёхслойный
```

`tasteCentroids()` переименовать в `tasteCentroidsLayer(layer string)` с
параметром вместо жёсткого `'all'`. Антипузырь (`c.aff < 0.4`) и штрафы за
артистов не трогаем — они калиброваны под диапазон `aff` 0..1, который не
меняется (все три слоя дают вклад 0..1, сумма весов = 1 → `aff` остаётся в
0..1).

### 3.5 Автопересчёт

Хук — в `litestore.Store.SaveSync` (`internal/litestore/litestore.go:392`),
после успешного `s.d.SaveSync(...)`:

```go
accepted, err := s.d.SaveSync(...)
if err == nil && hasTasteSignal(events, accepted) {
    s.scheduleRecompute()
}
return accepted, err
```

`hasTasteSignal` — среди принятых (`accepted`) событий есть хотя бы одно с
`Kind` из `{like, dislike, more_like, less_like, complete, skip, delete}`
(типы, реально пишущие в `feedback_event`, см. `recordFeedback`).

`scheduleRecompute()` — дебаунс + защита от параллельного запуска:

```go
type Store struct {
    d *localdb.DB
    recomputeMu sync.Mutex
    recomputeRunning atomic.Bool
    lastRecompute time.Time
}

func (s *Store) scheduleRecompute() {
    if s.recomputeRunning.Load() { return }
    s.recomputeMu.Lock()
    if time.Since(s.lastRecompute) < 5*time.Minute {
        s.recomputeMu.Unlock()
        return
    }
    s.lastRecompute = time.Now()
    s.recomputeMu.Unlock()
    if !s.recomputeRunning.CompareAndSwap(false, true) { return }
    go func() {
        defer s.recomputeRunning.Store(false)
        _, _, _ = s.d.RecomputeTasteClusters("long_term", nil)
        cutoff := time.Now().AddDate(0, 0, -21)
        _, _, _ = s.d.RecomputeTasteClusters("recent", &cutoff)
        s.bumpCentroidVersion()
    }()
}
```

(Образец флага «уже идёт» — как `importRunning atomic.Bool` в
`catalog.go:307`, тот же паттерн уже есть в проекте.)

Не чаще раза в 5 минут, и только если реально был вкусовой сигнал — иначе
k-means гонялся бы на каждый чих синка (каждые 3 минуты).

Плюс: разовый вызов того же пересчёта при старте `cmd/soundflow` (рядом с
уже существующей инициализацией БД) — чтобы `recent`-слой не был протухшим
неделю, если Alex не открывал приложение (окно 21 день едет, а без нового
события пересчёт иначе не наступит).

**Гонки с БД:** фоновая горутина пишет (`DELETE`+`INSERT` в транзакции)
одновременно с обычными запросами. `localdb.Open` (`cmd/soundflow/service.go`)
сейчас открывает SQLite без `busy_timeout` — под нагрузкой возможна
`database is locked`. Добавить `?_pragma=busy_timeout(5000)` в DSN открытия
(рядом уже есть пример в `cmd/soundflow-fingerprint`, где это сделано).

### 3.6 Новые HTTP-ручки — мимо `internal/api`

`internal/api.Store` — общий интерфейс с ДВУМЯ реализациями:
`internal/litestore.Store` (реальный, SQLite, используется в `cmd/soundflow`)
и `internal/db.Pool` (Postgres, используется только в мёртвом
`cmd/soundflow-server`, который аудит от 12.09.2026 пометил «ждёт решения
Alex» — не наше решение трогать его в этой задаче). Если бы новые методы
добавлялись в `api.Store`, пришлось бы реализовать их и в `db.Pool`, иначе
`go build ./...` падает — лишняя работа на мёртвый код без пользы.

Решение: новые ручки НЕ идут через `internal/api` — заводятся прямо в
`cmd/soundflow/service.go`, вызывают `s.db.*` (`*localdb.DB`) напрямую, по
образцу уже существующих `/api/taste/rebuild` (`cmd/soundflow/taste.go`).
Дублирования реализации на Postgres не требуется, `internal/api` и
`internal/db` не трогаем совсем.

Новый файл `cmd/soundflow/vectors.go`:

```go
// GET /api/taste/centroids-hash — версия слепка вкуса. Телефон дёргает
// после каждого синка; если хэш отличается от сохранённого локально —
// тянет полный /api/taste/centroids.
func (s *Service) hCentroidsHash(w http.ResponseWriter, r *http.Request) {
    writeJSON(w, map[string]string{"hash": s.db.TasteCentroidsHash()})
}

// GET /api/taste/centroids — long_term + recent центры, base64-блобы.
func (s *Service) hCentroids(w http.ResponseWriter, r *http.Request) {
    long, _ := s.db.TasteCentroidsLayerBlobs("long_term")
    recent, _ := s.db.TasteCentroidsLayerBlobs("recent")
    writeJSON(w, map[string]any{
        "hash": s.db.TasteCentroidsHash(),
        "long_term": long, "recent": recent,
    })
}

// POST /api/tracks/vectors {"ids": [...]} — отпечатки для пачки id
// (телефон дёргает сразу после скачивания трека). База64 в формате БД.
func (s *Service) hTrackVectors(w http.ResponseWriter, r *http.Request) {
    var req struct{ IDs []string `json:"ids"` }
    json.NewDecoder(r.Body).Decode(&req)
    out := map[string]string{}
    for _, id := range req.IDs {
        if v, ok, _ := s.db.FeatureVector(id); ok {
            out[id] = base64.StdEncoding.EncodeToString(vecToBlobBytes(v))
        }
    }
    writeJSON(w, map[string]any{"vectors": out})
}
```

`TasteCentroidsHash()` — sha256 от конкатенации всех блобов `long_term`+
`recent` центров (простая проверка «поменялось / не поменялось», не нужно
хранить версию отдельной колонкой — пересчитывается на лету по текущим
строкам `taste_cluster`, стоит копейки при разовом запросе после синка).

Регистрация маршрутов в `service.go` рядом с `/api/taste/rebuild`:
`/api/taste/centroids-hash`, `/api/taste/centroids`, `/api/tracks/vectors`.

## 4. Телефон (Flutter)

### 4.1 Новая таблица `track_vectors`

`lib/data/db.dart`, версия БД 5 → 6:

```dart
onUpgrade: (db, from, _) async {
  ...
  if (from < 6) await _createTrackVectors(db);
},
...
static Future<void> _createTrackVectors(Database db) => db.execute('''
      CREATE TABLE IF NOT EXISTS track_vectors (
        id  TEXT PRIMARY KEY,
        vec BLOB NOT NULL
      )
    ''');
```

`CREATE TABLE IF NOT EXISTS` вместо `ALTER TABLE` на существующей таблице —
идемпотентно, не трогает `downloaded_tracks` вообще (значит `SELECT *` из
`downloaded_tracks` не тяжелеет, `upsertDownloaded`/`ConflictAlgorithm.replace`
не может стереть то, чего в этой таблице нет).

Методы `Db`: `setTrackVector(String id, Uint8List vec)`,
`trackVector(String id) → Uint8List?`,
`trackVectorsFor(List<String> ids) → Map<String, Uint8List>` (одним
запросом `WHERE id IN (...)`, чтобы `_radio()` не делал N запросов).

### 4.2 kv: слепок вкуса + его хэш

Ключи в существующей `kv`: `taste_centroids_hash` (строка),
`taste_centroids` (JSON: `{"long_term": ["<base64>", ...], "recent": [...]}`,
каждый элемент — один центр).

### 4.3 Получение данных

`sync_repo.dart`, после успешного `_syncOnce`:

```dart
final localHash = await _db.kvGet('taste_centroids_hash');
final serverHash = await _api.tasteCentroidsHash();
if (serverHash != null && serverHash != localHash) {
  final data = await _api.tasteCentroids();
  if (data != null) {
    await _db.kvSet('taste_centroids_hash', data.hash);
    await _db.kvSet('taste_centroids', jsonEncode(data.toJson()));
  }
}
```

Две новые лёгкие ручки в `api.dart`: `tasteCentroidsHash()` (GET, просто
строка) и `tasteCentroids()` (GET, парсит `{hash, long_term, recent}`).

`downloads_repo.dart`, конец `download()` — после того как файл и метаданные
уже сохранены:

```dart
try {
  final vectors = await _api.trackVectors([id]);
  if (vectors[id] case final v?) {
    await _db.setTrackVector(id, v);
  }
} catch (_) {
  // отпечаток — необязательная надстройка, скачивание не должно падать из-за него
}
```

Новый метод `Api.trackVectors(List<String> ids)` → `POST /api/tracks/vectors`,
декодирует base64 в `Map<String, Uint8List>`.

### 4.4 Бэкфилл для уже скачанного

Новый метод `DownloadsRepo.backfillVectors()`, по образцу существующих
`backfillCovers()`/`backfillMeta()` — те вызываются в `main.dart` через
`unawaited(downloads.backfillCovers())` / `unawaited(downloads.backfillMeta())`
сразу при старте приложения; `backfillVectors()` добавляется туда же третьей
такой же строкой. Проходит по `downloaded_tracks`, для тех `id`, где
`track_vectors` пуст, шлёт `_api.trackVectors(ids)` пачками по ~200 (одна
ручка принимает список — не по одному треку), сохраняет пришедшее. Без
сети — тихо пропускает, попробует при следующем запуске.

### 4.5 Локальный ранжировщик (офлайн-радио)

Новый файл `lib/core/local_taste.dart`, чистый Dart, без внешних библиотек,
без сети:

```dart
class LocalCandidate {
  const LocalCandidate({required this.id, required this.artist});
  final String id;
  final String artist;
}

/// Смысл — как OrderRadio на сервере, но без слоя session и без штрафов
/// за артистов/скипы (для них нужна серверная история, которой нет
/// офлайн) — зато с правилом «не больше 2 подряд одного исполнителя»,
/// это чисто локальные данные (artist уже есть в downloaded_tracks).
List<String> orderOffline({
  required Float32List seedVec,
  required Map<String, Float32List> candidateVecs, // id -> вектор
  required Map<String, String> candidateArtists,    // id -> артист
  required List<Float32List> centroidsLongTerm,
  required List<Float32List> centroidsRecent,
}) {
  // sc = cosine(seed, v) + 0.15 * (0.60*affLong + 0.25*affRecent)
  // сортировка по sc убыванием, затем перестановка под правило ≤2 подряд
  // (тот же алгоритм, что merged-цикл в radio.go, без far-очереди —
  // антипузырь требует серверных данных о «далёких» треках истории, для
  // v1 офлайн опускаем).
}

double _cosine(Float32List a, Float32List b) { ... } // с защитой от нулевой нормы
double _maxAffinity(List<Float32List> centroids, Float32List v) { ... } // 0, если centroids пуст
```

Векторы читаются как `Float32List`, не `List<double>` (2048×3700 =
~7.6М double — десятки МБ, медленно). `sqflite` отдаёт BLOB как
`Uint8List`; прямой `Float32List.view(bytes.buffer)` может упасть на
выравнивании (`offsetInBytes` не обязан быть кратен 4) — читать через
`ByteData.sublistView(bytes).getFloat32(i*4, Endian.little)` в цикле, как
и сервер хранит (LE). Перед использованием вектора — проверка длины
байт == 8192 (2048×4), иначе пропустить трек (несовпадающая размерность —
старый кэш другой версии API).

Вызов из `_radio()` — в изоляте (`compute()`), не на UI-потоке: до ~3700
кандидатов × 2048 флоатов на сравнение с seed, плюс affinity к ~10 центрам —
заметное подвисание в главном потоке.

### 4.6 `_radio()` — включение фолбэка

`player_view.dart:294-332`, правка только `catch`-ветки:

```dart
try {
  final res = await ref.read(apiProvider).streamOrder(seedId: now.id, candidateIds: ids);
  if (!res.reordered) {
    // у seed нет отпечатка ни на сервере, ни (по построению) локально —
    // источник вектора один и тот же, локальный фолбэк здесь не поможет
    _toast('У этой песни нет звукового отпечатка — похожее не подобрать');
    return;
  }
  ... // как сейчас
} on DioException catch (_) {
  // именно сетевая ошибка — пробуем локальный фолбэк
  final tail = await _offlineRadioFallback(now, all);
  if (tail != null) {
    await _p.setSimilarTail(tail);
    _toast('Сервера нет — собрал похожее из уже скачанного');
    return;
  }
  _toast('Сервер не ответил — радио не собралось');
} catch (_) {
  _toast('Сервер не ответил — радио не собралось');
}
```

`_offlineRadioFallback` — читает `seed`+кандидатов из `track_vectors`,
центроиды из `kv`, зовёт `orderOffline` в изоляте; нет вектора у seed или
меньше 2 кандидатов с векторами → `null` (значит фолбэк не сработал, летим
в общий тост «радио не собралось» — так и должно быть на очень старых
скачиваниях до бэкфилла).

## 5. Что не делаем (явные YAGNI-решения, не молчаливые умолчания)

- Не квантуем/не сжимаем вектора — 8 КБ на трек поверх аудиофайла в
  мегабайтах не заметно, а квантизация — лишний код без нужды.
- Офлайн-радио не учитывает слой session и штрафы за нелюбимых
  артистов/недавние скипы — этих данных просто нет на телефоне без
  сервера; учитываем только правило «≤2 подряд одного исполнителя»
  (чисто локальные данные — artist уже есть в `downloaded_tracks`).
- Антипузырь офлайн не переносим — требует серверной статистики «далёких»
  треков по истории, не только текущих кандидатов.
- Вес `session` (0.15) фиксированный, НЕ растёт динамически после нескольких
  подряд согласованных действий, хотя TASTE-PLAN §3 такое описывает —
  отдельная небольшая доработка потом, если станет заметно нужна; для
  первой версии трёх слоёв это усложнение без проверенной пользы.
- Не трогаем `cmd/soundflow-server`/`internal/db` (Postgres) и не поднимаем
  вопрос его снятия — это отдельное решение из аудита 12.09.2026, ждёт
  Alex-а отдельно, не связано с этой задачей технически (см. §3.6).

## 6. Проверка на реальных данных перед тюнингом весов

TASTE-PLAN сам отмечает веса 0.60/0.25/0.15 как стартовые, требующие
подстройки по живой картине. Распределение `sim`/`aff` на реальной базе
Alex никем не измерено — эмбеддинги PANNs CNN14 неотрицательны, косинусы
могут сжиматься в узкий верхний диапазон, из-за чего порог антипузыря
(`aff < 0.4`) может не срабатывать вообще. Перед реализацией шага 3.4 —
разовый Go-тест (не деплой), который считает `sim`/`aff` по всей текущей
`soundflow-lab.db` и печатает гистограмму — чтобы веса и пороги в плане
опирались на измерение, а не на цифры с потолка. Если распределение сильно
не совпадёт с ожиданиями (0..1 диапазон) — обсудить с Alex поправку порога
до, а не после того, как радио начнёт вести себя неожиданно.

## 7. Порядок реализации (эскиз, полный план — отдельным файлом)

Мелкими коммитами, TDD, как делали автообновление. Тестовая база уже есть
с обеих сторон: `radio_test.go`, `taste_cluster_test.go` (сервер);
`test/db_test.dart`, `test/stream_test.dart` (телефон, фейковый `Api` +
in-memory sqflite).

1. `busy_timeout` в DSN открытия SQLite + `ORDER BY t.id` в
   `posScoredWithVector` (детерминизм) — тест на воспроизводимость центров.
2. Слои: `RecomputeTasteClusters(layer, since)` + порог минимума N + разовая
   миграция `DELETE layer='all'`. Тесты: пустой слой, слой ниже порога,
   `long_term` не задет фильтром по времени.
3. `sessionAffinity` по `client_ts`, только `like`, защита от кривых часов.
   Тест.
4. Гистограмма `sim`/`aff` на `soundflow-lab.db` (разовый Go-тест, §6) —
   смотрим на цифры, при необходимости правим пороги ПЕРЕД шагом 5.
5. `OrderRadio`: `aff := 0.60*affLong + 0.25*affRecent + 0.15*affSession`,
   `sc := sim + 0.15*aff` (дроп-ин, антипузырь/штрафы не трогать). Тест:
   при пустых `recent`/`session` порядок совпадает байт-в-байт с нынешним
   поведением (только `long_term`, эквивалент прежнего `'all'`).
6. Автопересчёт: дебаунс + флаг «уже идёт» + пересчёт при старте сервера.
7. Новые ручки: `/api/taste/centroids-hash`, `/api/taste/centroids`,
   `/api/tracks/vectors` — прямо в `cmd/soundflow`, мимо `internal/api`.
8. Телефон: таблица `track_vectors` (миграция v6), сохранение вектора при
   скачивании, `Api.trackVectors`/`tasteCentroids`/`tasteCentroidsHash`.
9. Телефон: `backfillVectors()` по образцу `backfillMeta`.
10. Телефон: `local_taste.dart` (косинус, `orderOffline`, защита от
    нулевой нормы, тесты).
11. `_radio()`: фолбэк только на сетевую ошибку (`DioException`), не на
    `reordered:false`.

Сборка APK — только по прямой просьбе Alex; после установки — явная фраза
«проверено на устройстве» / «не проверено на устройстве». Офлайн-фолбэк по
своей природе проверяется только руками на реальном телефоне с выключенным
сервером (эмулятор/дев-сборка это не подтверждает).
