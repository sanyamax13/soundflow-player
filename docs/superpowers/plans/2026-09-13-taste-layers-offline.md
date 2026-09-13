# Вкус в три слоя + офлайн-радио — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Прогресс (обновляется по ходу):** Task 1-5 и Task 13 — сделаны и
закоммичены (13.09.2026, коммиты `06f2a9a`..`4275306`). Task 5 заодно
нашла и починила реальный баг слияния антипузыря (дубль/потеря кандидата),
не связанный с формулой — см. коммит `e8b6e1c`. Task 13 (процентильный
порог антипузыря вместо мёртвого 0.4) сделана сразу следом, по горячим
следам Task 5 — проверена на реальной soundflow-lab.db. Задачи 6-12
(серверные ручки+автопересчёт, вся телефонная часть) — не начаты.

**Goal:** Разбить единый профиль вкуса на три слоя (long_term/recent/session), автоматизировать пересчёт, и научить телефон радио-фолбэку без сервера (по уже скачанным трекам).

**Architecture:** Сервер (Go, `apps/server`) остаётся единственным источником полного каталога и истории; он считает три слоя вкуса и отдаёт телефону только маленькие производные — центроиды (по хэшу) и отпечаток трека (по запросу после скачивания). Телефон (Flutter, `apps/mobile`) копит свою мини-базу отпечатков уже скачанного и, если сервер недоступен, сам считает приближённый порядок радио локально (cosine, без ML-библиотек).

**Tech Stack:** Go 1.x + `modernc.org/sqlite` + `chi` (сервер); Flutter/Dart + `sqflite` + `dio` (телефон); тесты — `go test`, `flutter test`.

**Spec:** `docs/superpowers/specs/2026-09-13-taste-layers-offline-design.md`

## Global Constraints

- Формула радио: `aff := 0.60*affLong + 0.25*affRecent + 0.15*affSession`, затем `sc := sim + 0.15*aff` — слои складываются МЕЖДУ СОБОЙ внутри `aff`, диапазон `aff` остаётся 0..1. Штрафы за артистов НЕ трогать. Антипузырь (порог «далеко от вкуса») — не трогать в Task 5, но Task 13 сознательно меняет его на процентильный вместо фиксированного 0.4 (обоснование и код — в Task 13).
- Новые HTTP-ручки сервера идут мимо `internal/api` — регистрируются прямо в `cmd/soundflow/service.go`, читают `*localdb.DB` напрямую. `internal/api/store.go` и `internal/db` (Postgres, мёртвый `cmd/soundflow-server`) не трогать вообще.
- Телефон: отпечаток трека — НОВАЯ таблица `track_vectors(id TEXT PRIMARY KEY, vec BLOB)`, не колонка в `downloaded_tracks`.
- Векторы на телефоне — `Uint8List`/`ByteData` (little-endian), не `List<double>`; тяжёлые сравнения (тысячи кандидатов × 2048 float) — в `compute()` (изолят), не на UI-потоке.
- `session` не хранится в БД — считается на лету, по `client_ts` (не `created_at`), только `event_type='like'`, максимум последних 5, без параметра `deviceID`.
- Порог: слой (`long_term`/`recent`) не строится при < 8 треков с положительной оценкой — вместо этого `DELETE` строк слоя, `aff` для него потом = 0.
- Офлайн-фолбэк в `_radio()` включается ТОЛЬКО при сетевой ошибке (`DioException`), не при `reordered:false`.
- Сборка APK — только по прямой просьбе Alex; после установки — явная фраза «проверено на устройстве» / «не проверено на устройстве».

---

## Task 1: SQLite busy_timeout + детерминизм пересчёта центров

**Files:**
- Modify: `apps/server/internal/localdb/localdb.go:33`
- Modify: `apps/server/internal/localdb/taste_cluster.go:14-19` (`posScoredWithVector`)
- Test: `apps/server/internal/localdb/taste_cluster_test.go`

**Interfaces:**
- Produces: `posScoredWithVector` теперь выбирает строки в стабильном порядке (`ORDER BY t.id`) — на это опирается Task 2.

- [ ] **Step 1: Открыть SQLite с `busy_timeout`, чтобы будущий фоновый пересчёт (Task 6) не ловил "database is locked"**

`apps/server/internal/localdb/localdb.go:33`, заменить:
```go
	h, err := sql.Open("sqlite", path)
```
на:
```go
	h, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)")
```
(Единственное место в кодовой базе, где открывается `soundflow.db` через этот драйвер — `cmd/soundflow-import/main.go:119` и `cmd/soundflow/service.go:81` оба зовут `localdb.Open(path)` без своих query-параметров, так что правка в одном месте покрывает оба вызывающих.)

- [ ] **Step 2: Написать тест на воспроизводимость центров при неизменных данных**

Добавить в конец `apps/server/internal/localdb/taste_cluster_test.go`:
```go
func TestRecomputeTasteClustersDeterministic(t *testing.T) {
	d := open(t)
	for i := 0; i < 20; i++ {
		v := make([]float32, VecDim)
		v[i%VecDim] = 1
		if _, err := d.sql.Exec(
			`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
			"t"+itoa(i), "A"+itoa(i%3), "t"+itoa(i), "t"+itoa(i), vecToBlob(v)); err != nil {
			t.Fatal(err)
		}
		if _, err := d.sql.Exec(
			`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, created_at)
			 VALUES (?,?,?,?,?,?)`,
			"e"+itoa(i), "t"+itoa(i), "A"+itoa(i%3), "like", 5.0, "2026-09-01T00:00:00Z"); err != nil {
			t.Fatal(err)
		}
	}
	nc1, _, err := d.RecomputeTasteClusters()
	if err != nil {
		t.Fatal(err)
	}
	first, err := d.tasteCentroids()
	if err != nil {
		t.Fatal(err)
	}
	nc2, _, err := d.RecomputeTasteClusters()
	if err != nil {
		t.Fatal(err)
	}
	second, err := d.tasteCentroids()
	if err != nil {
		t.Fatal(err)
	}
	if nc1 != nc2 || len(first) != len(second) {
		t.Fatalf("cluster count changed: %d/%d vs %d/%d", nc1, len(first), nc2, len(second))
	}
	for i := range first {
		if cosine(first[i], second[i]) < 0.999 {
			t.Errorf("centroid %d drifted between identical recomputes: cosine=%v", i, cosine(first[i], second[i]))
		}
	}
}
```

- [ ] **Step 3: Запустить тест — убедиться, что БЕЗ `ORDER BY` он может флапать (необязательно ловить флап живьём — сразу к фиксу)**

Run: `cd apps/server && go test ./internal/localdb/... -run TestRecomputeTasteClustersDeterministic -v -count=5`
Expected: PASS (SQLite обычно и так возвращает строки в порядке вставки без явного `ORDER BY`, поэтому тест может не показать проблему без нагрузки — фикс всё равно вносим, т.к. это не гарантия, а совпадение).

- [ ] **Step 4: Добавить `ORDER BY t.id` в `posScoredWithVector`**

`apps/server/internal/localdb/taste_cluster.go:14-19`, заменить:
```go
const posScoredWithVector = `
	SELECT t.id, t.artist, t.title, fe.s, t.feature_vector
	FROM tracks t
	JOIN (SELECT track_id, SUM(value) AS s FROM feedback_event
	      WHERE track_id <> '' GROUP BY track_id HAVING s > 0) fe ON fe.track_id = t.id
	WHERE t.feature_vector IS NOT NULL`
```
на:
```go
const posScoredWithVector = `
	SELECT t.id, t.artist, t.title, fe.s, fe.last_at, t.feature_vector
	FROM tracks t
	JOIN (SELECT track_id, SUM(value) AS s, MAX(created_at) AS last_at
	      FROM feedback_event
	      WHERE track_id <> '' GROUP BY track_id HAVING s > 0) fe ON fe.track_id = t.id
	WHERE t.feature_vector IS NOT NULL
	ORDER BY t.id`
```
(Столбец `fe.last_at` пока никем не читается — это подготовка к Task 2, где `RecomputeTasteClusters` и `TasteClusters` научатся его сканировать. Сейчас нужно синхронно поправить оба места, где идёт `rows.Scan(...)` по этому запросу, иначе будет `sql: expected N destination arguments in Scan, got N-1`.)

В `RecomputeTasteClusters` (`taste_cluster.go:42-53`):
```go
	var vecs [][]float32
	for rows.Next() {
		var id, artist, title, lastAt string
		var score float64
		var blob []byte
		if err := rows.Scan(&id, &artist, &title, &score, &lastAt, &blob); err != nil {
			rows.Close()
			return 0, 0, err
		}
		if v := blobToVec(blob); len(v) > 0 {
			vecs = append(vecs, l2norm(v))
		}
	}
```

В `TasteClusters` (`taste_cluster.go:203-213`):
```go
	for rows.Next() {
		var r TasteRow
		var lastAt string
		var blob []byte
		if err := rows.Scan(&r.ID, &r.Artist, &r.Title, &r.Score, &lastAt, &blob); err != nil {
			rows.Close()
			return nil, err
		}
```

- [ ] **Step 5: Прогнать весь пакет — ничего не должно сломаться**

Run: `cd apps/server && go test ./internal/localdb/... -v`
Expected: PASS (все существующие тесты + новый `TestRecomputeTasteClustersDeterministic`)

- [ ] **Step 6: Commit**

```bash
git add apps/server/internal/localdb/localdb.go apps/server/internal/localdb/taste_cluster.go apps/server/internal/localdb/taste_cluster_test.go
git commit -m "fix(server): busy_timeout на SQLite + детерминизм пересчёта центров вкуса"
```

---

## Task 2: Слои long_term/recent в RecomputeTasteClusters

**Files:**
- Modify: `apps/server/internal/localdb/taste_cluster.go`
- Modify: `apps/server/cmd/soundflow/taste.go`
- Modify: `apps/server/internal/localdb/localdb.go` (разовая миграция)
- Test: `apps/server/internal/localdb/taste_cluster_test.go`

**Interfaces:**
- Consumes: `posScoredWithVector` (с `fe.last_at`, Task 1).
- Produces: `func (d *DB) RecomputeTasteClusters(layer string, since *time.Time) (nClusters, nTracks int, err error)`; `func (d *DB) tasteCentroidsLayer(layer string) ([][]float32, error)` (заменяет старый `tasteCentroids()`); минимум 8 треков на слой — иначе `DELETE` и `nClusters=0`.

- [ ] **Step 1: Написать тест на слой с окном по времени и на порог минимума**

Добавить в `apps/server/internal/localdb/taste_cluster_test.go`:
```go
func TestRecomputeTasteClustersLayeredByTime(t *testing.T) {
	d := open(t)
	old := "2020-01-01T00:00:00Z"
	fresh := time.Now().UTC().Format(time.RFC3339)
	for i := 0; i < 10; i++ {
		v := make([]float32, VecDim)
		v[i%VecDim] = 1
		id := "old" + itoa(i)
		if _, err := d.sql.Exec(
			`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
			id, "A", id, id, vecToBlob(v)); err != nil {
			t.Fatal(err)
		}
		if _, err := d.sql.Exec(
			`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, created_at)
			 VALUES (?,?,?,?,?,?)`, "e"+id, id, "A", "like", 5.0, old); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 10; i++ {
		v := make([]float32, VecDim)
		v[(i+500)%VecDim] = 1
		id := "new" + itoa(i)
		if _, err := d.sql.Exec(
			`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
			id, "B", id, id, vecToBlob(v)); err != nil {
			t.Fatal(err)
		}
		if _, err := d.sql.Exec(
			`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, created_at)
			 VALUES (?,?,?,?,?,?)`, "e"+id, id, "B", "like", 5.0, fresh); err != nil {
			t.Fatal(err)
		}
	}

	ncLong, ntLong, err := d.RecomputeTasteClusters("long_term", nil)
	if err != nil {
		t.Fatal(err)
	}
	if ntLong != 20 {
		t.Errorf("long_term should see all 20 tracks, got %d", ntLong)
	}
	if ncLong == 0 {
		t.Error("long_term should build clusters")
	}

	cutoff := time.Now().AddDate(0, 0, -21)
	ncRecent, ntRecent, err := d.RecomputeTasteClusters("recent", &cutoff)
	if err != nil {
		t.Fatal(err)
	}
	if ntRecent != 10 {
		t.Errorf("recent should see only the 10 fresh tracks, got %d", ntRecent)
	}
	if ncRecent == 0 {
		t.Error("recent should build clusters (10 >= threshold 8)")
	}
}

func TestRecomputeTasteClustersBelowThreshold(t *testing.T) {
	d := open(t)
	for i := 0; i < 5; i++ { // ниже порога 8
		v := make([]float32, VecDim)
		v[i] = 1
		id := "t" + itoa(i)
		if _, err := d.sql.Exec(
			`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
			id, "A", id, id, vecToBlob(v)); err != nil {
			t.Fatal(err)
		}
		if _, err := d.sql.Exec(
			`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, created_at)
			 VALUES (?,?,?,?,?,?)`, "e"+id, id, "A", "like", 5.0, time.Now().UTC().Format(time.RFC3339)); err != nil {
			t.Fatal(err)
		}
	}
	nc, nt, err := d.RecomputeTasteClusters("long_term", nil)
	if err != nil {
		t.Fatal(err)
	}
	if nc != 0 {
		t.Errorf("below threshold (5 < 8) should build no clusters, got %d", nc)
	}
	if nt != 5 {
		t.Errorf("nTracks should still report the 5 seen, got %d", nt)
	}
	cents, err := d.tasteCentroidsLayer("long_term")
	if err != nil {
		t.Fatal(err)
	}
	if len(cents) != 0 {
		t.Errorf("layer table should be empty below threshold, got %d centroids", len(cents))
	}
}
```

- [ ] **Step 2: Запустить — должно упасть на несуществующей новой сигнатуре**

Run: `cd apps/server && go test ./internal/localdb/... -run TestRecomputeTasteClustersLayered -v`
Expected: FAIL (`too many arguments in call to d.RecomputeTasteClusters` / `undefined: d.tasteCentroidsLayer`)

- [ ] **Step 3: Переписать `RecomputeTasteClusters` и `tasteCentroids` на параметр слоя + окно + порог**

`apps/server/internal/localdb/taste_cluster.go`, заменить целиком функцию (строки ~33-90):
```go
// minClusterTracks — ниже этого числа треков с положительной оценкой слой
// не строится (иначе k-means на единицах треков даёт «центр = одна песня»,
// т.к. пустой кластер пересеивается случайным вектором из входных).
const minClusterTracks = 8

// RecomputeTasteClusters — пересобрать taste_cluster для одного слоя.
// since=nil — весь позитивный фидбек (long_term); since!=nil — только
// треки, чей ПОСЛЕДНИЙ положительный сигнал не старше since (recent).
// Меньше minClusterTracks треков — слой не строится, старые центры чистим.
func (d *DB) RecomputeTasteClusters(layer string, since *time.Time) (nClusters, nTracks int, err error) {
	rows, err := d.sql.Query(posScoredWithVector)
	if err != nil {
		return 0, 0, err
	}
	var vecs [][]float32
	for rows.Next() {
		var id, artist, title, lastAt string
		var score float64
		var blob []byte
		if err := rows.Scan(&id, &artist, &title, &score, &lastAt, &blob); err != nil {
			rows.Close()
			return 0, 0, err
		}
		if since != nil {
			lt, perr := time.Parse(time.RFC3339, lastAt)
			if perr != nil || lt.Before(*since) {
				continue
			}
		}
		if v := blobToVec(blob); len(v) > 0 {
			vecs = append(vecs, l2norm(v))
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, 0, err
	}
	nTracks = len(vecs)

	if len(vecs) < minClusterTracks {
		_, _ = d.sql.Exec(`DELETE FROM taste_cluster WHERE layer = ?`, layer)
		return 0, nTracks, nil
	}

	cents, assign := kmeansCosine(vecs, kFor(len(vecs)), 60, 42)
	counts := make([]int, len(cents))
	for _, a := range assign {
		counts[a]++
	}

	tx, err := d.sql.Begin()
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback() //nolint:errcheck
	if _, err := tx.Exec(`DELETE FROM taste_cluster WHERE layer = ?`, layer); err != nil {
		return 0, 0, err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	for i, c := range cents {
		if _, err := tx.Exec(
			`INSERT INTO taste_cluster (layer, idx, vec, n, updated_at) VALUES (?, ?, ?, ?, ?)`,
			layer, i, vecToBlob(c), counts[i], now); err != nil {
			return 0, 0, err
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, err
	}
	return len(cents), nTracks, nil
}

// tasteCentroidsLayer — центры вкуса одного слоя (нормированы при записи).
func (d *DB) tasteCentroidsLayer(layer string) ([][]float32, error) {
	rows, err := d.sql.Query(`SELECT vec FROM taste_cluster WHERE layer = ? ORDER BY idx`, layer)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]float32
	for rows.Next() {
		var b []byte
		if err := rows.Scan(&b); err != nil {
			return nil, err
		}
		if v := blobToVec(b); len(v) > 0 {
			out = append(out, v)
		}
	}
	return out, rows.Err()
}
```

Обновить оставшихся потребителей старого `tasteCentroids()`/`RecomputeTasteClusters()` в том же файле:
- `ScoreTracksByTaste` (было `cents, err := d.tasteCentroids()`) → `cents, err := d.tasteCentroidsLayer("long_term")`.
- `TasteClusters` (было `cents, err := d.tasteCentroids()`) → `cents, err := d.tasteCentroidsLayer("long_term")`.

- [ ] **Step 4: Обновить вызывающих в `cmd/soundflow/taste.go`**

`apps/server/cmd/soundflow/taste.go`, `hTasteRebuild` (было `nc, nt, cerr := s.db.RecomputeTasteClusters()`):
```go
func (s *Service) hTasteRebuild(w http.ResponseWriter, r *http.Request) {
	n, err := s.db.RebuildFeedback()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	ncLong, ntLong, cerr := s.db.RecomputeTasteClusters("long_term", nil)
	if cerr != nil {
		http.Error(w, cerr.Error(), 500)
		return
	}
	cutoff := time.Now().AddDate(0, 0, -21)
	ncRecent, ntRecent, cerr := s.db.RecomputeTasteClusters("recent", &cutoff)
	if cerr != nil {
		http.Error(w, cerr.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "",
		"пересобран вкус: "+strconv.Itoa(n)+" сигналов, "+strconv.Itoa(ncLong)+" долгих центров по "+strconv.Itoa(ntLong)+" трекам, "+strconv.Itoa(ncRecent)+" недавних по "+strconv.Itoa(ntRecent), 0)
	writeJSON(w, map[string]any{
		"rows": n,
		"long_term": map[string]int{"clusters": ncLong, "tracks": ntLong},
		"recent":    map[string]int{"clusters": ncRecent, "tracks": ntRecent},
	})
}
```
`hTasteCluster` — тем же образом (было `nc, nt, err := s.db.RecomputeTasteClusters()`):
```go
func (s *Service) hTasteCluster(w http.ResponseWriter, r *http.Request) {
	ncLong, ntLong, err := s.db.RecomputeTasteClusters("long_term", nil)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	cutoff := time.Now().AddDate(0, 0, -21)
	ncRecent, ntRecent, err := s.db.RecomputeTasteClusters("recent", &cutoff)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "",
		"пересчитаны центры вкуса: "+strconv.Itoa(ncLong)+" долгих по "+strconv.Itoa(ntLong)+", "+strconv.Itoa(ncRecent)+" недавних по "+strconv.Itoa(ntRecent), 0)
	writeJSON(w, map[string]any{
		"long_term": map[string]int{"clusters": ncLong, "tracks": ntLong},
		"recent":    map[string]int{"clusters": ncRecent, "tracks": ntRecent},
	})
}
```
Добавить `"time"` в импорты `taste.go`, если его там ещё нет.

- [ ] **Step 5: Разовая миграция — снести протухший слой `'all'`**

`apps/server/internal/localdb/localdb.go`, в список идемпотентных миграций (рядом со строками 42-55), добавить:
```go
		`DELETE FROM taste_cluster WHERE layer = 'all'`,
```
(Безопасно гонять на каждом старте: если строк с `layer='all'` уже нет, ничего не делает. Это derived-кэш, не пользовательские данные — реальные `long_term`/`recent` соберёт следующий пересчёт.)

- [ ] **Step 6: Обновить старые тесты, звавшие `RecomputeTasteClusters()`/`tasteCentroids()` без аргументов**

`grep -rn "RecomputeTasteClusters()\|tasteCentroids()" apps/server/internal/localdb/*_test.go` — в `radio_test.go`, `taste_suggest_test.go`, `taste_cluster_test.go` заменить `d.RecomputeTasteClusters()` → `d.RecomputeTasteClusters("long_term", nil)` (эти тесты проверяют долгий слой, поведение не меняется — раньше это был единственный слой `'all'`).

- [ ] **Step 7: Прогнать всё**

Run: `cd apps/server && go test ./... -v`
Expected: PASS (весь пакет, включая старые `TestOrderRadioTasteAware` и новые из Step 1)

- [ ] **Step 8: Commit**

```bash
git add apps/server/internal/localdb/taste_cluster.go apps/server/internal/localdb/localdb.go apps/server/internal/localdb/taste_cluster_test.go apps/server/internal/localdb/radio_test.go apps/server/internal/localdb/taste_suggest_test.go apps/server/cmd/soundflow/taste.go
git commit -m "feat(server): слои long_term/recent в RecomputeTasteClusters, порог минимума 8 треков"
```

---

## Task 3: session — живой сигнал «прямо сейчас»

**Files:**
- Create: `apps/server/internal/localdb/taste_session.go`
- Test: `apps/server/internal/localdb/taste_session_test.go`

**Interfaces:**
- Consumes: `feedback_event` (уже существующая таблица), `blobToVec`, `l2norm` (`vec.go`), `tasteAffinity` (`taste_cluster.go`).
- Produces: `func (d *DB) sessionVectors() ([][]float32, error)` — до 5 нормированных векторов последних лайков за 2 часа по `client_ts`; пусто — `nil, nil`. Task 4 подставляет результат прямо в `tasteAffinity`.

- [ ] **Step 1: Написать тест**

`apps/server/internal/localdb/taste_session_test.go`:
```go
package localdb

import (
	"testing"
	"time"
)

func sessionTrack(t *testing.T, d *DB, id string, axis int) {
	t.Helper()
	v := make([]float32, VecDim)
	v[axis] = 1
	if _, err := d.sql.Exec(
		`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
		id, "A", id, id, vecToBlob(v)); err != nil {
		t.Fatal(err)
	}
}

func likeEvent(t *testing.T, d *DB, uuid, trackID string, clientTS int64) {
	t.Helper()
	if _, err := d.sql.Exec(
		`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, client_ts, created_at)
		 VALUES (?,?,?,?,?,?,?)`,
		uuid, trackID, "A", "like", 5.0, clientTS, time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
}

func TestSessionVectorsRecentLikesOnly(t *testing.T) {
	d := open(t)
	now := time.Now()
	sessionTrack(t, d, "recent1", 0)
	sessionTrack(t, d, "old1", 1)
	likeEvent(t, d, "e1", "recent1", now.Add(-30*time.Minute).UnixMilli())
	likeEvent(t, d, "e2", "old1", now.Add(-3*time.Hour).UnixMilli()) // старше 2ч — не в сессию

	vecs, err := d.sessionVectors()
	if err != nil {
		t.Fatal(err)
	}
	if len(vecs) != 1 {
		t.Fatalf("expected 1 session vector (only recent1), got %d", len(vecs))
	}
}

func TestSessionVectorsIgnoresFinish(t *testing.T) {
	d := open(t)
	now := time.Now()
	sessionTrack(t, d, "played1", 0)
	if _, err := d.sql.Exec(
		`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, client_ts, created_at)
		 VALUES (?,?,?,?,?,?,?)`,
		"e1", "played1", "A", "finish", 1.5, now.Add(-10*time.Minute).UnixMilli(), time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	vecs, err := d.sessionVectors()
	if err != nil {
		t.Fatal(err)
	}
	if len(vecs) != 0 {
		t.Fatalf("finish events must not feed session (self-reinforcing loop) — got %d vecs", len(vecs))
	}
}

func TestSessionVectorsIgnoresBadClock(t *testing.T) {
	d := open(t)
	now := time.Now()
	sessionTrack(t, d, "future1", 0)
	sessionTrack(t, d, "ancient1", 1)
	likeEvent(t, d, "e1", "future1", now.Add(1*time.Hour).UnixMilli())     // из будущего
	likeEvent(t, d, "e2", "ancient1", now.Add(-48*time.Hour).UnixMilli()) // старше суток

	vecs, err := d.sessionVectors()
	if err != nil {
		t.Fatal(err)
	}
	if len(vecs) != 0 {
		t.Fatalf("clock-skewed events must be ignored, got %d vecs", len(vecs))
	}
}

func TestSessionVectorsNoLikes(t *testing.T) {
	d := open(t)
	vecs, err := d.sessionVectors()
	if err != nil {
		t.Fatal(err)
	}
	if vecs != nil {
		t.Fatalf("expected nil with no likes, got %v", vecs)
	}
}
```

- [ ] **Step 2: Запустить — падает, функции нет**

Run: `cd apps/server && go test ./internal/localdb/... -run TestSessionVectors -v`
Expected: FAIL (`undefined: d.sessionVectors`)

- [ ] **Step 3: Реализовать**

`apps/server/internal/localdb/taste_session.go`:
```go
package localdb

import "time"

// «Сессия» (TASTE-PLAN §3): что нравится прямо сейчас. НЕ хранится в
// taste_cluster — считается на лету, слишком мало данных для k-means и
// должен реагировать мгновенно. Берём только явные лайки (НЕ `finish` —
// finish срабатывает на каждой доигранной в радио песне, т.е. в режиме
// радио сессия собиралась бы из того, что радио само же и поставило —
// самоподкрепляющаяся петля). Максимум 5, не усредняем (TASTE-PLAN §3 п.4
// «не один центр — среднее по жанрам каша»): каждый лайк — свой вектор,
// tasteAffinity сама возьмёт максимум косинуса.
//
// Время — client_ts (часы ТЕЛЕФОНА), не created_at (время сервера): если
// телефон был без сети несколько дней, весь батч ляжет с created_at≈сейчас,
// и старые лайки стали бы «текущей сессией». Защита от кривых часов
// телефона: игнорируем client_ts из будущего или старше суток.
const (
	sessionWindow    = 2 * time.Hour
	sessionMaxEvents = 5
)

func (d *DB) sessionVectors() ([][]float32, error) {
	now := time.Now()
	cutoffMs := now.Add(-sessionWindow).UnixMilli()
	futureMs := now.UnixMilli()
	dayAgoMs := now.Add(-24 * time.Hour).UnixMilli()

	rows, err := d.sql.Query(`
		SELECT t.feature_vector
		FROM feedback_event fe
		JOIN tracks t ON t.id = fe.track_id
		WHERE fe.event_type = 'like'
		  AND fe.client_ts >= ? AND fe.client_ts <= ?
		  AND t.feature_vector IS NOT NULL
		ORDER BY fe.client_ts DESC
		LIMIT ?`,
		maxInt64(cutoffMs, dayAgoMs), futureMs, sessionMaxEvents)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]float32
	for rows.Next() {
		var blob []byte
		if err := rows.Scan(&blob); err != nil {
			return nil, err
		}
		if v := blobToVec(blob); len(v) > 0 {
			out = append(out, l2norm(v))
		}
	}
	return out, rows.Err()
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
```
(`cutoffMs` и `dayAgoMs` вместе реализуют «не старше 2ч, но и не считать событие, если из-за рассинхрона часов оно выглядит старше суток относительно `created_at`» — на практике `maxInt64` берёт более строгую (более позднюю) границу из двух, что для нормальных часов телефона равно просто `cutoffMs`, а для сильно отставших часов не даёт окну провалиться в далёкое прошлое.)

- [ ] **Step 4: Прогнать**

Run: `cd apps/server && go test ./internal/localdb/... -run TestSessionVectors -v`
Expected: PASS (все 4 теста)

- [ ] **Step 5: Commit**

```bash
git add apps/server/internal/localdb/taste_session.go apps/server/internal/localdb/taste_session_test.go
git commit -m "feat(server): sessionVectors — сигнал «вкус прямо сейчас», живой расчёт по client_ts"
```

---

## Task 4: Гистограмма sim/aff на реальной базе (разовое измерение)

**Files:**
- Create: `apps/server/internal/localdb/taste_histogram_test.go`

**Interfaces:**
- Не производит код, которым пользуются другие задачи — это диагностика перед Task 5, чтобы веса/пороги формулы опирались на измерение, а не на цифры «с потолка» (спек §6).

- [ ] **Step 1: Написать разовый тест-отчёт**

`apps/server/internal/localdb/taste_histogram_test.go`:
```go
package localdb

import (
	"fmt"
	"os"
	"testing"
)

// TestTasteHistogramReport — НЕ проверяет поведение, печатает распределение
// sim/aff на реальной базе перед тем, как менять формулу радио (Task 5).
// Пропускается, если SOUNDFLOW_LAB_DB не задан (обычный `go test ./...` его
// не запускает и не падает).
func TestTasteHistogramReport(t *testing.T) {
	path := os.Getenv("SOUNDFLOW_LAB_DB")
	if path == "" {
		t.Skip("SOUNDFLOW_LAB_DB не задан — пропуск (это разовая диагностика, не CI-тест)")
	}
	d, err := Open(path + "?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}
	cents, err := d.tasteCentroidsLayer("long_term")
	if err != nil {
		t.Fatal(err)
	}
	if len(cents) == 0 {
		t.Skip("нет центров вкуса на этой базе — гистограмма невозможна")
	}

	rows, err := d.sql.Query(`SELECT feature_vector FROM tracks WHERE feature_vector IS NOT NULL LIMIT 2000`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	buckets := make([]int, 10) // 0.0-0.1, 0.1-0.2, ..., 0.9-1.0
	n := 0
	for rows.Next() {
		var blob []byte
		if err := rows.Scan(&blob); err != nil {
			t.Fatal(err)
		}
		v := blobToVec(blob)
		if len(v) == 0 {
			continue
		}
		a := tasteAffinity(cents, v)
		bi := int(a * 10)
		if bi > 9 {
			bi = 9
		}
		buckets[bi]++
		n++
	}
	fmt.Printf("\n=== aff-гистограмма по %d трекам (long_term, %d центров) ===\n", n, len(cents))
	for i, c := range buckets {
		fmt.Printf("  %.1f-%.1f: %d (%.1f%%)\n", float64(i)/10, float64(i+1)/10, c, 100*float64(c)/float64(n))
	}
}
```

- [ ] **Step 2: Запустить на реальной базе и прочитать вывод**

Run: `cd apps/server && SOUNDFLOW_LAB_DB="E:/soundflow-lab/soundflow.db" go test ./internal/localdb/... -run TestTasteHistogramReport -v`
Expected: PASS, в выводе — таблица распределения `aff` по 10 корзинам.

Прочитать результат: если >80% треков попадают в `aff < 0.4` — порог антипузыря (`radio.go:114`, `c.aff < 0.4`) адекватен. Если, наоборот, почти все треки выше 0.4 (эмбеддинги PANNs CNN14 неотрицательны, косинусы могут сжиматься в узкий верхний диапазон) — до Task 5 обсудить с Alex через Telegram, не нужно ли поднять порог антипузыря (напр. до медианного значения из гистограммы). Не блокирующий шаг молчаливым предположением — если распределение выглядит нормально (заметная масса ниже 0.4), продолжать план как есть без правки порога.

- [ ] **Step 3: Commit (тест остаётся в репозитории — пригодится для будущей повторной проверки после накопления данных)**

```bash
git add apps/server/internal/localdb/taste_histogram_test.go
git commit -m "test(server): разовая гистограмма sim/aff для проверки порогов формулы радио"
```

---

## Task 5: OrderRadio — три слоя вместо одного (формула не подменяется!)

**Files:**
- Modify: `apps/server/internal/localdb/radio.go`
- Test: `apps/server/internal/localdb/radio_test.go`

**Interfaces:**
- Consumes: `tasteCentroidsLayer(layer)` (Task 2), `sessionVectors()` (Task 3), `tasteAffinity(cents, vec)` (не меняется).
- Produces: `OrderRadio` даёт тот же байт-в-байт порядок, что раньше, когда `recent`/`session` пусты (тест ниже).

- [ ] **Step 1: Написать тест на обратную совместимость (только long_term ≈ старый 'all')**

Добавить в `apps/server/internal/localdb/radio_test.go`:
```go
func TestOrderRadioMatchesOldBehaviorWhenNoRecentOrSession(t *testing.T) {
	d := open(t)
	radioTrack(t, d, "seed", "Seed", 0, 0)
	for i := 0; i < 4; i++ {
		radioTrack(t, d, "fav"+itoa(i), "Fav"+itoa(i), 0, float32(i)*0.01)
	}
	for i := 0; i < 4; i++ {
		radioTrack(t, d, "far"+itoa(i), "Far"+itoa(i), 700, float32(i)*0.01)
	}
	evs := []SyncEvent{}
	for i := 0; i < 4; i++ {
		evs = append(evs, SyncEvent{UUID: "l" + itoa(i), Kind: "like", TrackID: "fav" + itoa(i), Payload: json.RawMessage(``), ClientTS: 1})
	}
	if _, err := d.SaveSync(Device{ID: "d"}, evs); err != nil {
		t.Fatal(err)
	}
	// только long_term построен (8 любимых даже меньше — используем 4, значит
	// слой НЕ построится вовсе → aff=0 везде → должно совпасть с OrderBySimilarity)
	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}

	cands := []string{"far0", "fav0", "far1", "fav1", "far2", "fav2", "far3", "fav3"}
	got, reordered, err := d.OrderRadio("seed", cands)
	if err != nil {
		t.Fatal(err)
	}
	want, wantReordered, err := d.OrderBySimilarity("seed", cands)
	if err != nil {
		t.Fatal(err)
	}
	if reordered != wantReordered {
		t.Fatalf("reordered mismatch: got %v want %v", reordered, wantReordered)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("order diverged at %d: got %v want %v (full got=%v want=%v)", i, got[i], want[i], got, want)
		}
	}
}
```
(4 лайкнутых трека < порог 8 из Task 2 → `long_term` не построится → `OrderRadio` идёт по ветке "нет центров → `OrderBySimilarity`", это и есть проверка байт-в-байт совпадения.)

- [ ] **Step 2: Запустить — должен уже проходить (текущая ветка `len(cents)==0` уже это делает), это тест-фиксатор перед рефакторингом**

Run: `cd apps/server && go test ./internal/localdb/... -run TestOrderRadioMatchesOldBehavior -v`
Expected: PASS (ещё до правки — фиксирует поведение, которое Step 4 не должен сломать)

- [ ] **Step 3: Написать тест на смешивание трёх слоёв (recent важнее far, даже если long_term не знает про этот трек)**

```go
func TestOrderRadioBlendsThreeLayers(t *testing.T) {
	d := open(t)
	radioTrack(t, d, "seed", "Seed", 0, 0)
	// long_term: 8 треков жанра "ось 0" — тот же жанр, что seed
	for i := 0; i < 8; i++ {
		radioTrack(t, d, "old"+itoa(i), "Old"+itoa(i), 0, float32(i)*0.005)
	}
	// recent: 8 треков совсем другого жанра "ось 900" (недавно распробовал)
	for i := 0; i < 8; i++ {
		radioTrack(t, d, "recent"+itoa(i), "Recent"+itoa(i), 900, float32(i)*0.005)
	}
	// кандидат такого же звучания, как recent-жанр, но БЕЗ фидбека сам по себе
	radioTrack(t, d, "cand_recent_genre", "X", 900, 0.02)
	// кандидат далёкого жанра — не пересекается ни с одним слоем
	radioTrack(t, d, "cand_far", "Y", 300, 0)

	var evs []SyncEvent
	for i := 0; i < 8; i++ {
		evs = append(evs, SyncEvent{UUID: "old" + itoa(i), Kind: "like", TrackID: "old" + itoa(i), Payload: json.RawMessage(``), ClientTS: 1})
	}
	if _, err := d.SaveSync(Device{ID: "d"}, evs); err != nil {
		t.Fatal(err)
	}
	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}
	// recent-слой строим из отдельных фидбек-строк (не через SaveSync, чтобы
	// не задеть окно отбора long_term — сценарий "то же самое, но недавно")
	for i := 0; i < 8; i++ {
		if _, err := d.sql.Exec(
			`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, created_at)
			 VALUES (?,?,?,?,?,?)`,
			"rf"+itoa(i), "recent"+itoa(i), "Recent"+itoa(i), "like", 5.0, time.Now().UTC().Format(time.RFC3339)); err != nil {
			t.Fatal(err)
		}
	}
	cutoff := time.Now().AddDate(0, 0, -21)
	if _, _, err := d.RecomputeTasteClusters("recent", &cutoff); err != nil {
		t.Fatal(err)
	}

	cands := []string{"cand_far", "cand_recent_genre"}
	got, reordered, err := d.OrderRadio("seed", cands)
	if err != nil {
		t.Fatal(err)
	}
	if !reordered {
		t.Fatal("expected reordered")
	}
	pos := map[string]int{}
	for i, id := range got {
		pos[id] = i
	}
	if pos["cand_recent_genre"] > pos["cand_far"] {
		t.Errorf("recent-layer affinity should lift cand_recent_genre above cand_far: pos=%v", pos)
	}
}
```

- [ ] **Step 4: Запустить — падает (recent ещё не подмешан в формулу)**

Run: `cd apps/server && go test ./internal/localdb/... -run TestOrderRadioBlendsThreeLayers -v`
Expected: FAIL

- [ ] **Step 5: Переписать `OrderRadio` — три слоя внутри `aff`, `sc` не меняется**

`apps/server/internal/localdb/radio.go:31-42`, заменить:
```go
func (d *DB) OrderRadio(seedID string, candidateIDs []string) (ordered []string, reordered bool, err error) {
	seedVec, err := d.featureVector(seedID)
	if err != nil {
		return nil, false, err
	}
	centsLong, err := d.tasteCentroidsLayer("long_term")
	if err != nil {
		return nil, false, err
	}
	if len(seedVec) == 0 || len(centsLong) == 0 || len(candidateIDs) == 0 {
		return d.OrderBySimilarity(seedID, candidateIDs)
	}
	centsRecent, err := d.tasteCentroidsLayer("recent") // может быть пуст — affRecent тогда 0
	if err != nil {
		return nil, false, err
	}
	sessVecs, err := d.sessionVectors() // может быть nil — affSession тогда 0
	if err != nil {
		return nil, false, err
	}
```
(Условие входа в офлайн-ветку — `len(centsLong) == 0`, НЕ проверяем `centsRecent`/`sessVecs`: `long_term` — основной слой, без него вкус вообще не участвует; `recent`/`session` — опциональные добавки поверх него.)

И строку `radio.go:86-88`:
```go
		sim := cosine(seedVec, v)
		aff := tasteAffinity(cents, v)
		sc := sim + 0.15*aff
```
на:
```go
		sim := cosine(seedVec, v)
		affLong := tasteAffinity(centsLong, v)
		affRecent := tasteAffinity(centsRecent, v)
		affSession := tasteAffinity(sessVecs, v)
		aff := 0.60*affLong + 0.25*affRecent + 0.15*affSession
		sc := sim + 0.15*aff
```
(`tasteAffinity` уже возвращает 0 при пустом списке центров — работает без изменений и для `centsRecent`/`sessVecs`, когда они пусты.)

- [ ] **Step 6: Прогнать оба новых теста и весь пакет**

Run: `cd apps/server && go test ./internal/localdb/... -v`
Expected: PASS — включая `TestOrderRadioMatchesOldBehaviorWhenNoRecentOrSession`, `TestOrderRadioBlendsThreeLayers`, и старый `TestOrderRadioTasteAware` (антипузырь/штрафы не тронуты).

- [ ] **Step 7: Commit**

```bash
git add apps/server/internal/localdb/radio.go apps/server/internal/localdb/radio_test.go
git commit -m "feat(server): OrderRadio смешивает three layers вкуса (60/25/15) внутри aff, sc не меняется"
```

---

## Task 6: Автопересчёт после синка + при старте сервера

**Files:**
- Modify: `apps/server/internal/litestore/litestore.go`
- Modify: `apps/server/cmd/soundflow/service.go`
- Test: `apps/server/internal/litestore/litestore_test.go` (создать, если ещё нет теста для `Store`)

**Interfaces:**
- Consumes: `RecomputeTasteClusters(layer, since)` (Task 2), `d.SaveSync` (`internal/localdb/phone.go:72`, не меняется).
- Produces: `Store.SaveSync` пересчитывает `long_term`+`recent` в фоне, не чаще раза в 5 минут, только если среди принятых событий есть вкусовой сигнал; `Service.NewService` пересчитывает один раз при старте.

- [ ] **Step 1: Написать тест на дебаунс и на условие "только вкусовые события"**

Создать `apps/server/internal/litestore/litestore_test.go` (если файла нет — новый; если есть — дописать в конец):
```go
package litestore

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"soundflow/server/internal/db"
	"soundflow/server/internal/localdb"
)

func openStore(t *testing.T) *Store {
	t.Helper()
	d, err := localdb.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return New(d)
}

func TestSaveSyncSchedulesRecomputeOnTasteSignal(t *testing.T) {
	s := openStore(t)
	// без вкусового сигнала — не планируем пересчёт
	_, err := s.SaveSync(context.Background(), db.Device{ID: "d"}, []db.SyncEvent{
		{UUID: "u1", Kind: "download", TrackID: "t1", Payload: json.RawMessage(`{}`), ClientTS: 1},
	})
	if err != nil {
		t.Fatal(err)
	}
	if s.recomputeRunning.Load() {
		t.Error("download-событие не должно планировать пересчёт вкуса")
	}

	// с лайком — планируем (и он не «уже идёт» вечно — дожидаемся конца)
	_, err = s.SaveSync(context.Background(), db.Device{ID: "d"}, []db.SyncEvent{
		{UUID: "u2", Kind: "like", TrackID: "t1", Payload: json.RawMessage(`{}`), ClientTS: 2},
	})
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for s.recomputeRunning.Load() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if s.recomputeRunning.Load() {
		t.Error("пересчёт после like-события не завершился за 2с")
	}
}

func TestSaveSyncRecomputeDebounced(t *testing.T) {
	s := openStore(t)
	s.lastRecompute = time.Now() // как будто только что пересчитали
	_, err := s.SaveSync(context.Background(), db.Device{ID: "d"}, []db.SyncEvent{
		{UUID: "u1", Kind: "like", TrackID: "t1", Payload: json.RawMessage(`{}`), ClientTS: 1},
	})
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	if s.recomputeRunning.Load() {
		t.Error("пересчёт внутри 5-минутного окна дебаунса не должен запускаться")
	}
}
```

- [ ] **Step 2: Запустить — падает, полей `recomputeRunning`/`lastRecompute` нет**

Run: `cd apps/server && go test ./internal/litestore/... -v`
Expected: FAIL (`s.recomputeRunning undefined` и т.п.)

- [ ] **Step 3: Добавить дебаунс+флаг в `Store` и хук в `SaveSync`**

`apps/server/internal/litestore/litestore.go`, импорты — добавить `"sync"`, `"sync/atomic"`. Поле `Store` (строки 22-25):
```go
type Store struct {
	d   *localdb.DB
	raw *sql.DB

	recomputeMu      sync.Mutex
	recomputeRunning atomic.Bool
	lastRecompute    time.Time
}
```
(`time` уже импортирован в файле.)

`SaveSync` (строки 392-404), заменить:
```go
func (s *Store) SaveSync(ctx context.Context, dev db.Device, events []db.SyncEvent) ([]string, error) {
	le := make([]localdb.SyncEvent, len(events))
	for i, e := range events {
		le[i] = localdb.SyncEvent{UUID: e.UUID, Kind: e.Kind, TrackID: e.TrackID, Payload: e.Payload, ClientTS: e.ClientTS}
	}
	accepted, err := s.d.SaveSync(
		localdb.Device{
			ID: dev.ID, Name: dev.Name, AppVersion: dev.AppVersion,
			MusicBytes: dev.MusicBytes, Transport: dev.Transport,
		},
		le,
	)
	if err == nil && hasTasteSignal(events, accepted) {
		s.scheduleRecompute()
	}
	return accepted, err
}

// hasTasteSignal — среди принятых событий есть хоть одно, реально пишущее
// строку в feedback_event (см. recordFeedback в internal/localdb/taste.go).
func hasTasteSignal(events []db.SyncEvent, accepted []string) bool {
	acc := make(map[string]bool, len(accepted))
	for _, u := range accepted {
		acc[u] = true
	}
	tasteKinds := map[string]bool{
		"like": true, "dislike": true, "more_like": true, "less_like": true,
		"complete": true, "skip": true, "delete": true,
	}
	for _, e := range events {
		if acc[e.UUID] && tasteKinds[e.Kind] {
			return true
		}
	}
	return false
}

// scheduleRecompute — фоновый пересчёт long_term+recent, не чаще раза в
// 5 минут, с флагом "уже идёт" (тот же паттерн, что importRunning в
// internal/api/catalog.go:307 — обход библиотеки тоже не должен идти
// параллельно сам с собой).
func (s *Store) scheduleRecompute() {
	if s.recomputeRunning.Load() {
		return
	}
	s.recomputeMu.Lock()
	if time.Since(s.lastRecompute) < 5*time.Minute {
		s.recomputeMu.Unlock()
		return
	}
	s.lastRecompute = time.Now()
	s.recomputeMu.Unlock()
	if !s.recomputeRunning.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer s.recomputeRunning.Store(false)
		_, _, _ = s.d.RecomputeTasteClusters("long_term", nil)
		cutoff := time.Now().AddDate(0, 0, -21)
		_, _, _ = s.d.RecomputeTasteClusters("recent", &cutoff)
	}()
}
```

- [ ] **Step 4: Прогнать**

Run: `cd apps/server && go test ./internal/litestore/... -v`
Expected: PASS

- [ ] **Step 5: Разовый пересчёт при старте сервера**

`apps/server/cmd/soundflow/service.go`, в `NewService()`, сразу после успешного `db, err := localdb.Open(dbPath)` (строка 81-84), добавить:
```go
	db, err := localdb.Open(dbPath)
	if err != nil {
		return nil, fmt.Errorf("база %s: %w", dbPath, err)
	}
	// Слой 'recent' протухает по времени (окно 21 день), а не только по
	// событиям — пересчитываем и при старте, чтобы неделю простоя не
	// показывала позапрошлый месяц до первого нового лайка.
	go func() {
		_, _, _ = db.RecomputeTasteClusters("long_term", nil)
		cutoff := time.Now().AddDate(0, 0, -21)
		_, _, _ = db.RecomputeTasteClusters("recent", &cutoff)
	}()
```

- [ ] **Step 6: Прогнать всё, собрать сервер (проверка компиляции)**

Run: `cd apps/server && go build ./... && go test ./... -v`
Expected: PASS, сборка без ошибок.

- [ ] **Step 7: Commit**

```bash
git add apps/server/internal/litestore/litestore.go apps/server/internal/litestore/litestore_test.go apps/server/cmd/soundflow/service.go
git commit -m "feat(server): автопересчёт слоёв вкуса после синка (дебаунс 5мин) и при старте сервера"
```

---

## Task 7: Новые ручки — центроиды и отпечатки треков

**Files:**
- Create: `apps/server/cmd/soundflow/vectors.go`
- Modify: `apps/server/cmd/soundflow/service.go` (регистрация маршрутов)
- Test: `apps/server/cmd/soundflow/vectors_test.go`

**Interfaces:**
- Consumes: `s.db.FeatureVector(id)` (`write.go:99`, уже есть), `s.db.TasteCentroidsHash()`/`s.db.TasteCentroidsLayerBlobs(layer)` (новые экспортируемые методы `localdb.DB`, этот task их добавляет).
- Produces: `GET /api/taste/centroids-hash` → `{"hash": "..."}`; `GET /api/taste/centroids` → `{"hash", "long_term": [...base64], "recent": [...base64]}`; `POST /api/tracks/vectors {"ids":[...]}` → `{"vectors": {"id": "base64", ...}}`. Task 9 (телефон) — прямой потребитель этих трёх ответов.

- [ ] **Step 1: Добавить экспортируемые методы в `localdb` (хэш + блобы по слою)**

Дописать в конец `apps/server/internal/localdb/taste_cluster.go`:
```go
// TasteCentroidsHash — sha256 от конкатенации всех центров long_term+recent,
// по порядку (layer, idx). Меняется, только когда центры реально другие —
// используется телефоном, чтобы не тянуть блобы при каждой синхронизации.
func (d *DB) TasteCentroidsHash() (string, error) {
	h := sha256.New()
	for _, layer := range []string{"long_term", "recent"} {
		rows, err := d.sql.Query(`SELECT vec FROM taste_cluster WHERE layer = ? ORDER BY idx`, layer)
		if err != nil {
			return "", err
		}
		for rows.Next() {
			var b []byte
			if err := rows.Scan(&b); err != nil {
				rows.Close()
				return "", err
			}
			h.Write(b)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return "", err
		}
		rows.Close()
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// TasteCentroidsLayerBlobs — центры одного слоя, как base64 (для HTTP-ответа
// телефону — тот же формат BLOB, что в БД, little-endian float32).
func (d *DB) TasteCentroidsLayerBlobs(layer string) ([]string, error) {
	cents, err := d.tasteCentroidsLayer(layer)
	if err != nil {
		return nil, err
	}
	out := make([]string, len(cents))
	for i, c := range cents {
		out[i] = base64.StdEncoding.EncodeToString(vecToBlob(c))
	}
	return out, nil
}
```
Добавить в импорты `taste_cluster.go`: `"crypto/sha256"`, `"encoding/base64"`, `"encoding/hex"`.

- [ ] **Step 2: Написать тест на новые методы `localdb`**

Добавить в `apps/server/internal/localdb/taste_cluster_test.go`:
```go
func TestTasteCentroidsHashChangesWithData(t *testing.T) {
	d := open(t)
	h1, err := d.TasteCentroidsHash()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10; i++ {
		v := make([]float32, VecDim)
		v[i] = 1
		id := "t" + itoa(i)
		if _, err := d.sql.Exec(
			`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
			id, "A", id, id, vecToBlob(v)); err != nil {
			t.Fatal(err)
		}
		if _, err := d.sql.Exec(
			`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, created_at)
			 VALUES (?,?,?,?,?,?)`, "e"+id, id, "A", "like", 5.0, time.Now().UTC().Format(time.RFC3339)); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}
	h2, err := d.TasteCentroidsHash()
	if err != nil {
		t.Fatal(err)
	}
	if h1 == h2 {
		t.Error("hash should change after building long_term clusters")
	}
	h3, err := d.TasteCentroidsHash()
	if err != nil {
		t.Fatal(err)
	}
	if h2 != h3 {
		t.Error("hash should be stable when data unchanged")
	}
	blobs, err := d.TasteCentroidsLayerBlobs("long_term")
	if err != nil {
		t.Fatal(err)
	}
	if len(blobs) == 0 {
		t.Error("expected at least one base64 centroid")
	}
}
```

- [ ] **Step 3: Запустить**

Run: `cd apps/server && go test ./internal/localdb/... -run TestTasteCentroidsHash -v`
Expected: PASS

- [ ] **Step 4: Написать HTTP-хендлеры**

`apps/server/cmd/soundflow/vectors.go`:
```go
package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
)

// Ручки телефона для трёхслойного вкуса и офлайн-отпечатков (docs/TASTE-PLAN.md,
// docs/superpowers/specs/2026-09-13-taste-layers-offline-design.md §3.6).
// Сознательно МИМО internal/api — вызывают s.db напрямую, по образцу
// /api/taste/rebuild в taste.go. internal/api.Store имеет вторую реализацию
// на Postgres (мёртвый cmd/soundflow-server) — заводить туда эти методы
// незачем.

// GET /api/taste/centroids-hash — телефон дёргает после каждой синхронизации;
// если хэш отличается от сохранённого локально, тянет полный /api/taste/centroids.
func (s *Service) hCentroidsHash(w http.ResponseWriter, r *http.Request) {
	hash, err := s.db.TasteCentroidsHash()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]string{"hash": hash})
}

// GET /api/taste/centroids — центры long_term+recent, base64.
func (s *Service) hCentroids(w http.ResponseWriter, r *http.Request) {
	hash, err := s.db.TasteCentroidsHash()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	long, err := s.db.TasteCentroidsLayerBlobs("long_term")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	recent, err := s.db.TasteCentroidsLayerBlobs("recent")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]any{"hash": hash, "long_term": long, "recent": recent})
}

// POST /api/tracks/vectors {"ids": [...]} — отпечатки для пачки id
// (телефон дёргает сразу после скачивания трека и при бэкфилле старых).
func (s *Service) hTrackVectors(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad json", 400)
		return
	}
	out := map[string]string{}
	for _, id := range req.IDs {
		v, ok, err := s.db.FeatureVector(id)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		if !ok {
			continue
		}
		out[id] = base64.StdEncoding.EncodeToString(vecToBlobPublic(v))
	}
	writeJSON(w, map[string]any{"vectors": out})
}
```
`vecToBlob` в `localdb` — неэкспортируемая (`vec.go:14`), а `vectors.go` живёт в `package main`. Добавить публичную обёртку в `apps/server/internal/localdb/vec.go`, сразу после `vecToBlob`:
```go
// VecToBlob — экспортируемая обёртка vecToBlob, для кода вне пакета (HTTP-ручки).
func VecToBlob(v []float32) []byte { return vecToBlob(v) }
```
И в `vectors.go` заменить `vecToBlobPublic(v)` → `localdb.VecToBlob(v)`, добавить импорт `"soundflow/server/internal/localdb"`.

- [ ] **Step 5: Зарегистрировать маршруты**

`apps/server/cmd/soundflow/service.go`, в `mountAPI` (строка 161-163), сразу после `/api/taste/cluster`:
```go
	r.Get("/api/taste", s.hTaste)
	r.Post("/api/taste/rebuild", s.hTasteRebuild)
	r.Post("/api/taste/cluster", s.hTasteCluster)
	r.Get("/api/taste/centroids-hash", s.hCentroidsHash)
	r.Get("/api/taste/centroids", s.hCentroids)
	r.Post("/api/tracks/vectors", s.hTrackVectors)
```

- [ ] **Step 6: Написать HTTP-тест ручек**

`apps/server/cmd/soundflow/vectors_test.go`:
```go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"soundflow/server/internal/localdb"
)

func testService(t *testing.T) *Service {
	t.Helper()
	db, err := localdb.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return &Service{db: db}
}

func TestHCentroidsHashEmpty(t *testing.T) {
	s := testService(t)
	req := httptest.NewRequest(http.MethodGet, "/api/taste/centroids-hash", nil)
	w := httptest.NewRecorder()
	s.hCentroidsHash(w, req)
	if w.Code != 200 {
		t.Fatalf("status %d", w.Code)
	}
	var resp map[string]string
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	if resp["hash"] == "" {
		t.Error("expected a non-empty hash even with no clusters")
	}
}

func TestHTrackVectorsMissingIDSkipped(t *testing.T) {
	s := testService(t)
	v := make([]float32, localdb.VecDim)
	v[0] = 1
	if err := s.db.SetFeatureVector("t1", v); err != nil {
		t.Fatal(err)
	}
	// t1 не в каталоге (нет строки в tracks) — SetFeatureVector его создаст?
	// нет: SetFeatureVector делает UPDATE, без строки в tracks запись не появится.
	// Проверяем на реально существующей строке через INSERT напрямую:
	if _, err := s.db.SQL().Exec(
		`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
		"real1", "A", "real1", "real1", localdb.VecToBlob(v)); err != nil {
		t.Fatal(err)
	}
	body := strings.NewReader(`{"ids":["real1","missing1"]}`)
	req := httptest.NewRequest(http.MethodPost, "/api/tracks/vectors", body)
	w := httptest.NewRecorder()
	s.hTrackVectors(w, req)
	if w.Code != 200 {
		t.Fatalf("status %d", w.Code)
	}
	var resp struct {
		Vectors map[string]string `json:"vectors"`
	}
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	if _, ok := resp.Vectors["real1"]; !ok {
		t.Error("expected real1 in response")
	}
	if _, ok := resp.Vectors["missing1"]; ok {
		t.Error("missing1 has no vector — should be omitted, not present")
	}
}
```
(`d.SQL()` — проверить, что такой публичный геттер уже есть в `localdb.DB`; если нет — заменить в тесте прямой вставкой через уже имеющийся паттерн из `radio_test.go`, т.е. использовать тестовый хелпер `radioTrack`-подобный, но он в другом пакете (`localdb_test`, не `main`) — вместо этого просто оставить `INSERT` как в примере выше, убрать первую (лишнюю) попытку через `SetFeatureVector`+`SQL()`.)

Упростить тест, убрав недостижимый путь — переписать `TestHTrackVectorsMissingIDSkipped` без `s.db.SQL()`:
```go
func TestHTrackVectorsMissingIDSkipped(t *testing.T) {
	s := testService(t)
	v := make([]float32, localdb.VecDim)
	v[0] = 1
	if err := s.db.SetFeatureVector("real1", v); err != nil {
		t.Fatal(err)
	}
	// SetFeatureVector — это UPDATE; без строки в tracks она не создаётся,
	// значит нужен путь через каталог. Раз в localdb нет публичного метода
	// "вставить трек" для тестов вне пакета, дергаем FeatureVector напрямую:
	// если ok=false, тест ниже это и проверяет по ветке missing1 — а для
	// real1 достаточно того, что FeatureVector(real1) видит записанный вектор
	// НЕЗАВИСИМО от наличия строки в tracks (см. write.go: SetFeatureVector
	// делает `UPDATE tracks SET feature_vector=? WHERE id=?` — 0 строк
	// затронуто, если id нет; тогда FeatureVector тоже вернёт ok=false).
	// Поэтому здесь реально нужен трек в каталоге — используем acquire-подобный
	// путь недоступен в этом тесте; переносим проверку "видит существующий id"
	// в internal/localdb (Task 2/7 уже покрывают FeatureVector отдельно) и
	// здесь тестируем только форму ответа и то, что отсутствующий id тихо
	// пропускается:
	got, ok, err := s.db.FeatureVector("real1")
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatal("setup invariant changed: real1 unexpectedly has a vector without a tracks row — update this test")
	}
	_ = got

	body := strings.NewReader(`{"ids":["missing1"]}`)
	req := httptest.NewRequest(http.MethodPost, "/api/tracks/vectors", body)
	w := httptest.NewRecorder()
	s.hTrackVectors(w, req)
	if w.Code != 200 {
		t.Fatalf("status %d", w.Code)
	}
	var resp struct {
		Vectors map[string]string `json:"vectors"`
	}
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Vectors) != 0 {
		t.Errorf("no ids should resolve, got %v", resp.Vectors)
	}
}
```

- [ ] **Step 7: Прогнать, при необходимости поправить тест по реальному поведению `SetFeatureVector`**

Run: `cd apps/server && go test ./... -v`
Expected: PASS. Если `TestHTrackVectorsMissingIDSkipped` в исполнении покажет другое поведение `SetFeatureVector`/`FeatureVector` (например, `tracks` строка всё же создаётся где-то ещё) — поправить тест по факту, сохранив цель проверки: отсутствующий id тихо пропускается, найденный — присутствует в ответе как base64.

- [ ] **Step 8: Commit**

```bash
git add apps/server/internal/localdb/taste_cluster.go apps/server/internal/localdb/taste_cluster_test.go apps/server/internal/localdb/vec.go apps/server/cmd/soundflow/vectors.go apps/server/cmd/soundflow/vectors_test.go apps/server/cmd/soundflow/service.go
git commit -m "feat(server): ручки /api/taste/centroids(-hash) и /api/tracks/vectors для телефона"
```

---

## Task 8: Телефон — таблица `track_vectors`

**Files:**
- Modify: `apps/mobile/lib/data/db.dart`
- Test: `apps/mobile/test/db_test.dart`

**Interfaces:**
- Produces: `Db.setTrackVector(String id, Uint8List vec)`, `Db.trackVector(String id) → Future<Uint8List?>`, `Db.trackVectorsFor(List<String> ids) → Future<Map<String, Uint8List>>`. Task 10/11 их используют.

- [ ] **Step 1: Написать тест**

Добавить в конец `apps/mobile/test/db_test.dart` (внутри существующего `main()`, новый `test(...)`):
```dart
  test('вектор трека сохраняется и читается отдельной таблицей', () async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);

    expect(await db.trackVector('t1'), isNull);

    final vec = Uint8List.fromList(List.generate(8192, (i) => i % 256));
    await db.setTrackVector('t1', vec);
    final got = await db.trackVector('t1');
    expect(got, isNotNull);
    expect(got, vec);

    // перезапись тем же id — не дублирует строку
    final vec2 = Uint8List.fromList(List.filled(8192, 7));
    await db.setTrackVector('t1', vec2);
    expect(await db.trackVector('t1'), vec2);

    await db.setTrackVector('t2', vec);
    final many = await db.trackVectorsFor(['t1', 't2', 'missing']);
    expect(many.length, 2);
    expect(many['t1'], vec2);
    expect(many['t2'], vec);
    expect(many.containsKey('missing'), isFalse);

    await db.close();
  });
```
Добавить в начало файла импорт `import 'dart:typed_data';`, если его ещё нет.

- [ ] **Step 2: Запустить — падает, методов нет**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/db_test.dart`
Expected: FAIL (`The method 'trackVector' isn't defined for the class 'Db'`)

- [ ] **Step 3: Добавить таблицу и методы**

`apps/mobile/lib/data/db.dart`, версия БД и миграция (строки 14-40):
```dart
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: (db, _) async {
          await _createDownloads(db);
          await _createSync(db);
          await _createRemoved(db);
          await _createTrackVectors(db);
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) await _createSync(db);
          if (from < 3) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN cover_path TEXT');
          }
          if (from < 4) await _createRemoved(db);
          if (from < 5) {
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN bitrate_kbps INTEGER');
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN format TEXT');
            await db.execute('ALTER TABLE downloaded_tracks ADD COLUMN duration_sec INTEGER');
          }
          if (from < 6) await _createTrackVectors(db);
        },
      ),
    );
```
Новый статический метод, рядом с `_createRemoved` (после строки 71):
```dart
  /// Звуковые отпечатки уже скачанных песен — для офлайн-радио, когда
  /// сервер недоступен. ОТДЕЛЬНАЯ таблица, не колонка в downloaded_tracks:
  /// downloaded_tracks читается целиком в автосинке каждые 3 минуты и в
  /// списке «Моя музыка» — колонка на 8 КБ раздула бы эти чтения, а
  /// INSERT OR REPLACE при повторной докачке (redownload/_fetchCoverFor)
  /// затирал бы значение, если явно не перечислить его в каждом апдейте.
  static Future<void> _createTrackVectors(Database db) => db.execute('''
        CREATE TABLE IF NOT EXISTS track_vectors (
          id  TEXT PRIMARY KEY,
          vec BLOB NOT NULL
        )
      ''');
```
Новые методы, рядом с блоком `// --- kv ---` (после строки 252, перед `Future<void> close()`):
```dart
  // --- Отпечатки треков (офлайн-радио) ---

  Future<void> setTrackVector(String id, Uint8List vec) => _db.insert(
        'track_vectors',
        {'id': id, 'vec': vec},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<Uint8List?> trackVector(String id) async {
    final rows = await _db.query('track_vectors', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first['vec'] as Uint8List;
  }

  Future<Map<String, Uint8List>> trackVectorsFor(List<String> ids) async {
    if (ids.isEmpty) return {};
    final q = List.filled(ids.length, '?').join(',');
    final rows = await _db.query('track_vectors', where: 'id IN ($q)', whereArgs: ids);
    return {
      for (final r in rows) r['id'] as String: r['vec'] as Uint8List,
    };
  }
```
Добавить `import 'dart:typed_data';` в начало `db.dart`, если его там нет.

- [ ] **Step 4: Прогнать**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/db_test.dart`
Expected: PASS

- [ ] **Step 5: Прогнать весь набор тестов телефона — старая миграция v5 не должна пострадать**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test`
Expected: PASS (весь набор, включая существующие)

- [ ] **Step 6: Commit**

```bash
git add apps/mobile/lib/data/db.dart apps/mobile/test/db_test.dart
git commit -m "feat(mobile): таблица track_vectors (миграция v6) — кэш отпечатков для офлайн-радио"
```

---

## Task 9: Телефон — новые методы `Api`

**Files:**
- Modify: `apps/mobile/lib/data/api.dart`
- Test: `apps/mobile/test/api_taste_test.dart`

**Interfaces:**
- Consumes: `/api/taste/centroids-hash`, `/api/taste/centroids`, `/api/tracks/vectors` (Task 7).
- Produces: `Api.tasteCentroidsHash() → Future<String?>`; `Api.tasteCentroids() → Future<TasteCentroids?>` (новый класс `TasteCentroids{hash, longTerm, recent}`, поля — `List<Uint8List>`); `Api.trackVectors(List<String> ids) → Future<Map<String, Uint8List>>`. Task 10 их использует.

- [ ] **Step 1: Написать тест с фейковым `HttpClientAdapter` (тот же паттерн, что `update_check_test.dart`)**

`apps/mobile/test/api_taste_test.dart`:
```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/data/api.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);
  final Map<String, Map<String, dynamic>> responses; // path -> json body

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = responses[options.path];
    if (body == null) {
      return ResponseBody.fromString('not found', 404, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

void main() {
  test('tasteCentroidsHash читает поле hash', () async {
    final api = Api(baseUrl: 'http://test');
    api.debugAdapter = _FakeAdapter({
      '/api/taste/centroids-hash': {'hash': 'abc123'},
    });
    expect(await api.tasteCentroidsHash(), 'abc123');
  });

  test('tasteCentroidsHash — сервер недоступен → null', () async {
    final api = Api(baseUrl: 'http://test');
    api.debugAdapter = _FakeAdapter({});
    expect(await api.tasteCentroidsHash(), isNull);
  });

  test('tasteCentroids декодирует base64 в векторы слоёв', () async {
    final api = Api(baseUrl: 'http://test');
    final vecBytes = base64Encode(Uint8List.fromList(List.filled(8, 1)));
    api.debugAdapter = _FakeAdapter({
      '/api/taste/centroids': {
        'hash': 'h1',
        'long_term': [vecBytes],
        'recent': <String>[],
      },
    });
    final res = await api.tasteCentroids();
    expect(res, isNotNull);
    expect(res!.hash, 'h1');
    expect(res.longTerm.length, 1);
    expect(res.recent, isEmpty);
  });

  test('trackVectors декодирует карту id->base64, пропускает отсутствующие', () async {
    final api = Api(baseUrl: 'http://test');
    final vecBytes = base64Encode(Uint8List.fromList(List.filled(8, 2)));
    api.debugAdapter = _FakeAdapter({
      '/api/tracks/vectors': {
        'vectors': {'t1': vecBytes},
      },
    });
    final res = await api.trackVectors(['t1', 't2']);
    expect(res.length, 1);
    expect(res['t1'], isNotNull);
    expect(res.containsKey('t2'), isFalse);
  });
}
```
(Проверить перед написанием: у класса `Api` уже должен быть способ подменить адаптер в тестах — если готового сеттера нет, добавить его этим же шагом, см. Step 2.)

- [ ] **Step 2: Проверить/добавить точку подмены адаптера в `Api`**

`apps/mobile/lib/data/api.dart`, класс `Api` (строки 14-23) — добавить сеттер, если в кодовой базе такого ещё нет (`grep -n "httpClientAdapter" apps/mobile/lib/data/api.dart apps/mobile/test/*.dart` — если `update_check_test.dart` подменяет адаптер напрямую через конструктор `Dio()`, а не через `Api`, то `Api` таким сеттером не пользовался раньше; добавить):
```dart
  /// Только для тестов — подменить HTTP-адаптер фейковым.
  set debugAdapter(HttpClientAdapter a) => _dio.httpClientAdapter = a;
```

- [ ] **Step 3: Запустить — падает, методов `Api` ещё нет**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/api_taste_test.dart`
Expected: FAIL (`The method 'tasteCentroidsHash' isn't defined`)

- [ ] **Step 4: Реализовать**

Добавить в `apps/mobile/lib/data/api.dart`, после `waveform()` (после строки ~146, до `postSyncEvents`):
```dart
  /// Слепок вкуса — только версия (несколько байт), НЕ сами центры. Дёргаем
  /// после каждой синхронизации; если отличается от сохранённого локально —
  /// тянем полный [tasteCentroids]. Сервер недоступен → null (тихо, вкус
  /// не критичен для работы приложения).
  Future<String?> tasteCentroidsHash() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/api/taste/centroids-hash');
      return res.data?['hash'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Полный слепок вкуса (центры long_term+recent) — только когда хэш
  /// разошёлся с локальным (см. [tasteCentroidsHash]).
  Future<TasteCentroids?> tasteCentroids() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/api/taste/centroids');
      final data = res.data;
      if (data == null) return null;
      List<Uint8List> decode(String key) => [
            for (final s in (data[key] as List? ?? const []))
              base64Decode('$s'),
          ];
      return TasteCentroids(
        hash: '${data['hash'] ?? ''}',
        longTerm: decode('long_term'),
        recent: decode('recent'),
      );
    } catch (_) {
      return null;
    }
  }

  /// Отпечатки треков — телефон дёргает сразу после скачивания и при
  /// разовом бэкфилле старых скачиваний. Отсутствующий id — тихо пропущен
  /// (не у каждого трека в каталоге есть отпечаток).
  Future<Map<String, Uint8List>> trackVectors(List<String> ids) async {
    if (ids.isEmpty) return {};
    try {
      final res = await _dio.post<Map<String, dynamic>>('/api/tracks/vectors', data: {'ids': ids});
      final vectors = (res.data?['vectors'] as Map?) ?? const {};
      return {
        for (final e in vectors.entries) '${e.key}': base64Decode('${e.value}'),
      };
    } catch (_) {
      return {};
    }
  }
```
И новый класс, в конец файла (или сразу после класса `AcquireException`):
```dart
/// Слепок вкуса, пришедший с сервера — центры long_term+recent как «сырые»
/// векторы (little-endian float32, 8192 байта на каждый при VecDim=2048).
class TasteCentroids {
  const TasteCentroids({required this.hash, required this.longTerm, required this.recent});
  final String hash;
  final List<Uint8List> longTerm;
  final List<Uint8List> recent;
}
```
Добавить импорты в начало `api.dart`, если их нет: `import 'dart:convert';`, `import 'dart:typed_data';`.

- [ ] **Step 5: Прогнать**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/api_taste_test.dart`
Expected: PASS

- [ ] **Step 6: Прогнать весь набор**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add apps/mobile/lib/data/api.dart apps/mobile/test/api_taste_test.dart
git commit -m "feat(mobile): Api.tasteCentroidsHash/tasteCentroids/trackVectors"
```

---

## Task 10: Телефон — сохранение вектора при скачивании, слепок вкуса при синке, бэкфилл

**Files:**
- Modify: `apps/mobile/lib/data/downloads_repo.dart`
- Modify: `apps/mobile/lib/data/sync_repo.dart`
- Modify: `apps/mobile/lib/main.dart`
- Test: `apps/mobile/test/downloads_repo_vectors_test.dart`, `apps/mobile/test/sync_repo_test.dart` (дописать, если файл уже есть — проверить `Glob apps/mobile/test/*.dart` при исполнении; если `sync_repo_test.dart` не существует — создать)

**Interfaces:**
- Consumes: `Db.setTrackVector`/`trackVectorsFor` (Task 8), `Api.trackVectors`/`tasteCentroidsHash`/`tasteCentroids` (Task 9), `Db.kvGet`/`kvSet` (уже есть).
- Produces: `DownloadsRepo.backfillVectors()`; побочный эффект — `download()` и `SyncRepo.sync()` сами наполняют `track_vectors`/`kv`. Task 12 (`_radio()`) читает результат через `Db`.

- [ ] **Step 1: Тест — скачивание сохраняет вектор, ошибка сети не валит скачивание**

`apps/mobile/test/downloads_repo_vectors_test.dart`:
```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';

class _FakeApi extends Api {
  _FakeApi({this.vectorFor});
  final Uint8List? Function(String id)? vectorFor;

  @override
  Future<void> downloadTrack(String id, String toPath) async {}

  @override
  Future<Map<String, Uint8List>> trackVectors(List<String> ids) async {
    if (vectorFor == null) throw Exception('network down');
    final out = <String, Uint8List>{};
    for (final id in ids) {
      final v = vectorFor!(id);
      if (v != null) out[id] = v;
    }
    return out;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('скачивание сохраняет отпечаток трека', () async {
    final vec = Uint8List.fromList(List.filled(8, 5));
    final api = _FakeApi(vectorFor: (id) => id == 't1' ? vec : null);
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final repo = DownloadsRepo(api, db);

    await repo.download({'id': 't1', 'title': 'T', 'artist': 'A'});

    expect(await db.trackVector('t1'), vec);
    await db.close();
  });

  test('нет сети для отпечатка — скачивание всё равно успешно', () async {
    final api = _FakeApi(vectorFor: null); // trackVectors бросит исключение
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final repo = DownloadsRepo(api, db);

    final size = await repo.download({'id': 't1', 'title': 'T', 'artist': 'A'});

    expect(size, isA<int>());
    expect(await db.trackVector('t1'), isNull);
    expect(await db.downloadedById('t1'), isNotNull);
    await db.close();
  });
}
```
(`downloadTrack` у `_FakeApi` переопределён пустым телом — реальный `File(path).length()` внутри `download()` будет читать несуществующий файл и упадёт; проверить по факту исполнения Step 2 — если так, доопределить `_FakeApi` так, чтобы `downloadTrack` создавал пустой файл по `toPath` через `File(toPath).create(recursive: true)` перед возвратом, и обновить оба теста на это допущение.)

- [ ] **Step 2: Запустить — скорее всего упадёт на реальном файловом I/O, поправить фейк**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/downloads_repo_vectors_test.dart`
Expected: сначала, вероятно, FAIL на `File(path).length()` (файла нет) — поправить `_FakeApi.downloadTrack`:
```dart
  @override
  Future<void> downloadTrack(String id, String toPath) async {
    await File(toPath).create(recursive: true);
  }
```
(добавить `import 'dart:io';` в тестовый файл), затем перезапустить. После этой правки ожидаемый результат первого прогона — FAIL именно на отсутствии метода `trackVectors`-интеграции в `download()` (т.к. она ещё не написана), не на файловом I/O.

- [ ] **Step 3: `DownloadsRepo.download()` — сохранить вектор после скачивания**

`apps/mobile/lib/data/downloads_repo.dart`, конец метода `download()` (после `await _db.upsertDownloaded(...)`, ищи закрывающую часть метода после строки ~70 из уже прочитанного фрагмента — там, где метод возвращает `size`), добавить перед `return size;`:
```dart
    // Отпечаток — необязательная надстройка для офлайн-радио (Task 12);
    // нет сети/старая версия сервера — молча пропускаем, попробует
    // backfillVectors() при следующем запуске.
    try {
      final vectors = await _api.trackVectors([id]);
      if (vectors[id] case final v?) {
        await _db.setTrackVector(id, v);
      }
    } catch (_) {}

    return size;
```

- [ ] **Step 4: Прогнать**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/downloads_repo_vectors_test.dart`
Expected: PASS

- [ ] **Step 5: Тест — `backfillVectors()` докачивает отпечатки для старых скачиваний, пачками**

Добавить в `apps/mobile/test/downloads_repo_vectors_test.dart`:
```dart
  test('backfillVectors докачивает отпечатки только тем, у кого их нет', () async {
    final calls = <List<String>>[];
    final vec = Uint8List.fromList(List.filled(8, 9));
    final api = _FakeApi(vectorFor: (id) => vec)
      ..onTrackVectorsCall = calls.add;
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final repo = DownloadsRepo(api, db);
    await db.upsertDownloaded(DownloadedTrack(id: 'old1', title: 'x', artist: 'y', path: '/tmp/old1', bytes: 1, addedAt: 1));
    await db.upsertDownloaded(DownloadedTrack(id: 'old2', title: 'x', artist: 'y', path: '/tmp/old2', bytes: 1, addedAt: 2));
    await db.setTrackVector('old2', vec); // у old2 уже есть — не должен попасть в запрос

    await repo.backfillVectors();

    expect(calls, isNotEmpty);
    expect(calls.expand((x) => x), contains('old1'));
    expect(calls.expand((x) => x), isNot(contains('old2')));
    expect(await db.trackVector('old1'), vec);
    await db.close();
  });
```
И расширить `_FakeApi`:
```dart
class _FakeApi extends Api {
  _FakeApi({this.vectorFor});
  final Uint8List? Function(String id)? vectorFor;
  void Function(List<String> ids)? onTrackVectorsCall;

  @override
  Future<void> downloadTrack(String id, String toPath) async {
    await File(toPath).create(recursive: true);
  }

  @override
  Future<Map<String, Uint8List>> trackVectors(List<String> ids) async {
    onTrackVectorsCall?.call(ids);
    if (vectorFor == null) throw Exception('network down');
    final out = <String, Uint8List>{};
    for (final id in ids) {
      final v = vectorFor!(id);
      if (v != null) out[id] = v;
    }
    return out;
  }
}
```

- [ ] **Step 6: Запустить — падает, `backfillVectors()` не существует**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/downloads_repo_vectors_test.dart`
Expected: FAIL (`The method 'backfillVectors' isn't defined`)

- [ ] **Step 7: Реализовать `backfillVectors()` по образцу `backfillMeta()`**

Добавить в `apps/mobile/lib/data/downloads_repo.dart`, сразу после `backfillMeta()` (после строки 240):
```dart
  /// Докачать отпечатки уже скачанным трекам, у которых их ещё нет — для
  /// офлайн-радио (см. docs/superpowers/specs/2026-09-13-taste-layers-offline-design.md
  /// §4.4). Пачками по 200 (одна ручка принимает список, не по одному
  /// треку). Фоном при старте, как backfillCovers/backfillMeta.
  Future<void> backfillVectors() async {
    final all = await _db.allDownloaded();
    final have = await _db.trackVectorsFor([for (final t in all) t.id]);
    final need = [for (final t in all) if (!have.containsKey(t.id)) t.id];
    if (need.isEmpty) return;
    const chunk = 200;
    for (var i = 0; i < need.length; i += chunk) {
      final part = need.sublist(i, i + chunk > need.length ? need.length : i + chunk);
      Map<String, Uint8List> vectors;
      try {
        vectors = await _api.trackVectors(part);
      } catch (_) {
        return; // нет сети — попробуем в следующий раз, со следующего же куска не гонимся
      }
      for (final entry in vectors.entries) {
        await _db.setTrackVector(entry.key, entry.value);
      }
    }
  }
```
Добавить `import 'dart:typed_data';` в начало `downloads_repo.dart`, если его нет.

- [ ] **Step 8: Прогнать**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/downloads_repo_vectors_test.dart`
Expected: PASS

- [ ] **Step 9: `main.dart` — зарегистрировать бэкфилл при старте**

`apps/mobile/lib/main.dart`, после строки 75 (`unawaited(downloads.backfillMeta());`):
```dart
  unawaited(downloads.backfillMeta());
  // Отпечатки для офлайн-радио уже скачанным трекам — фоном, как и два
  // backfill выше (13.09.2026).
  unawaited(downloads.backfillVectors());
```

- [ ] **Step 10: `SyncRepo` — тянуть слепок вкуса после успешного синка, по хэшу**

Проверить, есть ли уже `apps/mobile/test/sync_repo_test.dart` (`ls apps/mobile/test/sync_repo_test.dart`). Если нет — создать с нуля; если есть — дописать в конец `main()`. Тест:
```dart
  test('после синка тянет centroids только если хэш изменился', () async {
    final calls = <String>[];
    final api = _FakeApiForCentroids(
      hash: 'h1',
      onHashCall: () => calls.add('hash'),
      onCentroidsCall: () => calls.add('centroids'),
    );
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    final sync = SyncRepo(api, db);
    await sync.record('like', trackId: 't1');

    await sync.sync();
    expect(calls, ['hash', 'centroids']);
    expect(await db.kvGet('taste_centroids_hash'), 'h1');

    calls.clear();
    await sync.record('like', trackId: 't2');
    await sync.sync();
    // хэш не поменялся на сервере — centroids второй раз не тянем
    expect(calls, ['hash']);

    await db.close();
  });
```
Нужен фейковый `Api` для этого теста (в том же файле, выше `main()`):
```dart
class _FakeApiForCentroids extends Api {
  _FakeApiForCentroids({required this.hash, this.onHashCall, this.onCentroidsCall});
  final String hash;
  final void Function()? onHashCall;
  final void Function()? onCentroidsCall;

  @override
  Future<List<String>> postSyncEvents({
    required String deviceId,
    required List<Map<String, Object?>> events,
    int musicBytes = 0,
    String deviceName = 'Android',
    String transport = '',
  }) async =>
      [for (final e in events) '${e['uuid']}'];

  @override
  Future<String?> tasteCentroidsHash() async {
    onHashCall?.call();
    return hash;
  }

  @override
  Future<TasteCentroids?> tasteCentroids() async {
    onCentroidsCall?.call();
    return TasteCentroids(hash: hash, longTerm: const [], recent: const []);
  }
}
```
(Если `sync_repo_test.dart` уже существует с другими фейками/структурой — переиспользовать существующий класс фейкового `Api` в файле, добавив в него `tasteCentroidsHash`/`tasteCentroids` вместо создания нового класса, чтобы не плодить дублирующиеся моки.)

- [ ] **Step 11: Запустить — падает, `SyncRepo` ещё не тянет centroids**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/sync_repo_test.dart`
Expected: FAIL

- [ ] **Step 12: Реализовать в `SyncRepo`**

`apps/mobile/lib/data/sync_repo.dart`, добавить константу рядом с `_kDeviceId`/`_kLastSync` (строки 20-21):
```dart
  static const _kTasteHash = 'taste_centroids_hash';
  static const _kTasteData = 'taste_centroids';
```
В `_syncOnce`, перед `return (sent: accepted.length, pending: ...)` (после строки 111, `await _db.kvSet(_kLastSync, ...)`):
```dart
    await _pullTasteCentroidsIfChanged();

    return (sent: accepted.length, pending: await _db.pendingCount());
```
Новый приватный метод, в конец класса перед закрывающей `}`:
```dart
  /// Слепок вкуса — тянем только когда хэш на сервере разошёлся с тем, что
  /// уже сохранено (иначе при частых синках гоняли бы одни и те же
  /// центры лишний раз). Сеть недоступна/сервер старой версии — тихо
  /// пропускаем, следующий синк попробует снова.
  Future<void> _pullTasteCentroidsIfChanged() async {
    final serverHash = await _api.tasteCentroidsHash();
    if (serverHash == null) return;
    final localHash = await _db.kvGet(_kTasteHash);
    if (serverHash == localHash) return;
    final data = await _api.tasteCentroids();
    if (data == null) return;
    await _db.kvSet(_kTasteHash, data.hash);
    await _db.kvSet(
      _kTasteData,
      jsonEncode({
        'long_term': [for (final v in data.longTerm) base64Encode(v)],
        'recent': [for (final v in data.recent) base64Encode(v)],
      }),
    );
  }
```
(`jsonEncode`/`base64Encode` — из `dart:convert`, уже импортирован в `sync_repo.dart` строка 1.)

- [ ] **Step 13: Прогнать**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/sync_repo_test.dart`
Expected: PASS

- [ ] **Step 14: Прогнать весь набор телефона**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test`
Expected: PASS (весь набор — известный предсуществующий сбой `search_test.dart`, если он есть, не в счёт — не наша правка)

- [ ] **Step 15: Commit**

```bash
git add apps/mobile/lib/data/downloads_repo.dart apps/mobile/lib/data/sync_repo.dart apps/mobile/lib/main.dart apps/mobile/test/downloads_repo_vectors_test.dart apps/mobile/test/sync_repo_test.dart
git commit -m "feat(mobile): скачивание сохраняет отпечаток, синк тянет слепок вкуса по хэшу, бэкфилл старых"
```

---

## Task 11: Телефон — локальный ранжировщик (офлайн-радио)

**Files:**
- Create: `apps/mobile/lib/core/local_taste.dart`
- Test: `apps/mobile/test/local_taste_test.dart`

**Interfaces:**
- Consumes: ничего из предыдущих задач напрямую (чистая функция) — данные (векторы/центроиды) ей передаёт Task 12.
- Produces: `List<String> orderOffline({required Float32List seedVec, required Map<String, Float32List> candidateVecs, required Map<String, String> candidateArtists, required List<Float32List> centroidsLongTerm, required List<Float32List> centroidsRecent})`; `Float32List bytesToVec(Uint8List bytes)` (конвертация BLOB → Float32List с проверкой длины и выравнивания).

- [ ] **Step 1: Написать тесты**

`apps/mobile/test/local_taste_test.dart`:
```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundflow/core/local_taste.dart';

Uint8List _vecBytes(List<double> values) {
  final bd = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    bd.setFloat32(i * 4, values[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

Float32List _vec(List<double> values) => Float32List.fromList(values.map((e) => e.toDouble()).toList());

void main() {
  group('bytesToVec', () {
    test('декодирует little-endian float32', () {
      final bytes = _vecBytes([1.0, 0.0, -1.0]);
      final v = bytesToVec(bytes);
      expect(v, isNotNull);
      expect(v!.length, 3);
      expect(v[0], closeTo(1.0, 1e-6));
      expect(v[2], closeTo(-1.0, 1e-6));
    });

    test('неверная длина (не кратна 4 или не совпадает с ожидаемой) — null', () {
      expect(bytesToVec(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('offsetInBytes не ноль — всё равно декодируется верно', () {
      final full = _vecBytes([9.0, 1.0, 2.0, 3.0]);
      final sub = Uint8List.sublistView(full, 4); // offset=4, не кратно ничему особому, но >0
      final v = bytesToVec(sub);
      expect(v, isNotNull);
      expect(v!.length, 3);
      expect(v[0], closeTo(1.0, 1e-6));
    });
  });

  group('orderOffline', () {
    test('ранжирует по похожести на seed + affinity к long_term центру', () {
      final seed = _vec([1, 0, 0, 0]);
      final close = _vec([0.9, 0.1, 0, 0]);
      final far = _vec([0, 0, 0, 1]);
      final result = orderOffline(
        seedVec: seed,
        candidateVecs: {'close': close, 'far': far},
        candidateArtists: {'close': 'A', 'far': 'B'},
        centroidsLongTerm: [seed],
        centroidsRecent: const [],
      );
      expect(result.first, 'close');
    });

    test('пустые центры вкуса — не падает, сортирует по звуку', () {
      final seed = _vec([1, 0]);
      final close = _vec([0.9, 0.1]);
      final far = _vec([0, 1]);
      final result = orderOffline(
        seedVec: seed,
        candidateVecs: {'close': close, 'far': far},
        candidateArtists: {'close': 'A', 'far': 'B'},
        centroidsLongTerm: const [],
        centroidsRecent: const [],
      );
      expect(result.first, 'close');
    });

    test('нулевой вектор кандидата не роняет функцию (защита от деления на ноль)', () {
      final seed = _vec([1, 0]);
      final zero = _vec([0, 0]);
      final result = orderOffline(
        seedVec: seed,
        candidateVecs: {'zero': zero},
        candidateArtists: {'zero': 'A'},
        centroidsLongTerm: const [],
        centroidsRecent: const [],
      );
      expect(result, ['zero']);
    });

    test('не больше 2 подряд одного исполнителя', () {
      final seed = _vec([1, 0]);
      final vecs = {
        'a1': _vec([1, 0]), 'a2': _vec([0.99, 0.01]), 'a3': _vec([0.98, 0.02]),
        'b1': _vec([0.5, 0.5]),
      };
      final artists = {'a1': 'A', 'a2': 'A', 'a3': 'A', 'b1': 'B'};
      final result = orderOffline(
        seedVec: seed,
        candidateVecs: vecs,
        candidateArtists: artists,
        centroidsLongTerm: const [],
        centroidsRecent: const [],
      );
      // все три "A" ближе к seed, чем "B" — без правила ≤2 подряд result
      // был бы [a1,a2,a3,b1]; с правилом b1 должен встать после первых двух A
      var run = 0;
      String? last;
      for (final id in result) {
        final artist = artists[id];
        if (artist == last) {
          run++;
        } else {
          run = 1;
          last = artist;
        }
        expect(run, lessThanOrEqualTo(2), reason: 'result=$result');
      }
    });
  });
}
```

- [ ] **Step 2: Запустить — падает, файла нет**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/local_taste_test.dart`
Expected: FAIL (`Error: Not found: 'package:soundflow/core/local_taste.dart'`)

- [ ] **Step 3: Реализовать**

`apps/mobile/lib/core/local_taste.dart`:
```dart
import 'dart:typed_data';

/// Офлайн-версия OrderRadio (apps/server/internal/localdb/radio.go) — без
/// сети, только среди уже скачанных треков. Без слоя session и без штрафов
/// за нелюбимых артистов/недавние скипы (для них нужна серверная история,
/// которой на телефоне нет) — но с правилом «не больше 2 подряд одного
/// исполнителя» (artist уже есть в downloaded_tracks, чисто локальные
/// данные). Формула — как sc := sim + 0.15*aff в radio.go, aff — блендед
/// 0.60*long+0.25*recent (без session, см.
/// docs/superpowers/specs/2026-09-13-taste-layers-offline-design.md §4.5).

/// BLOB (little-endian float32) → Float32List. Проверяет длину (кратна 4);
/// НЕ делает Float32List.view напрямую — sqflite может вернуть Uint8List с
/// ненулевым offsetInBytes, на котором `.view()` падает при невыровненном
/// смещении, поэтому читаем через ByteData.getFloat32 в цикле.
Float32List? bytesToVec(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  final n = bytes.length ~/ 4;
  final bd = ByteData.sublistView(bytes);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getFloat32(i * 4, Endian.little);
  }
  return out;
}

double _cosine(Float32List a, Float32List b) {
  if (a.length != b.length || a.isEmpty) return 0;
  double dot = 0, na = 0, nb = 0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (_sqrt(na) * _sqrt(nb));
}

double _sqrt(double x) {
  if (x <= 0) return 0;
  var guess = x;
  for (var i = 0; i < 20; i++) {
    guess = 0.5 * (guess + x / guess);
  }
  return guess;
}

double _maxAffinity(List<Float32List> centroids, Float32List v) {
  if (centroids.isEmpty || v.isEmpty) return 0;
  var best = 0.0;
  for (final c in centroids) {
    final s = _cosine(c, v);
    if (s > best) best = s;
  }
  return best;
}

/// Порядок кандидатов: похожесть на seed + лёгкая добавка вкуса (60% долгий
/// + 25% недавний, без session), затем перестановка под правило «не больше
/// 2 подряд одного исполнителя» (тот же merge-цикл, что в radio.go, без
/// far-очереди антипузыря — она требует серверной статистики, которой нет
/// офлайн).
List<String> orderOffline({
  required Float32List seedVec,
  required Map<String, Float32List> candidateVecs,
  required Map<String, String> candidateArtists,
  required List<Float32List> centroidsLongTerm,
  required List<Float32List> centroidsRecent,
}) {
  final scored = <MapEntry<String, double>>[];
  for (final entry in candidateVecs.entries) {
    final v = entry.value;
    final sim = _cosine(seedVec, v);
    final affLong = _maxAffinity(centroidsLongTerm, v);
    final affRecent = _maxAffinity(centroidsRecent, v);
    final aff = 0.60 * affLong + 0.25 * affRecent;
    final sc = sim + 0.15 * aff;
    scored.add(MapEntry(entry.key, sc));
  }
  scored.sort((a, b) {
    final c = b.value.compareTo(a.value);
    return c != 0 ? c : a.key.compareTo(b.key);
  });

  final pool = [for (final e in scored) e.key];
  final ordered = <String>[];
  String? lastArtist;
  var run = 0;
  while (pool.isNotEmpty) {
    var pick = 0;
    if (run >= 2) {
      final alt = pool.indexWhere((id) => candidateArtists[id] != lastArtist);
      if (alt != -1) pick = alt;
    }
    final id = pool.removeAt(pick);
    ordered.add(id);
    final artist = candidateArtists[id];
    if (artist == lastArtist) {
      run++;
    } else {
      lastArtist = artist;
      run = 1;
    }
  }
  return ordered;
}
```
(`_sqrt` — метод Ньютона в 20 итераций вместо `dart:math`, чтобы файл оставался «чистый Dart, без внешних библиотек» согласно спеку §4.5 — на деле `dart:math` доступен всегда и его использование было бы проще; заменить на `import 'dart:math' as math;` и `math.sqrt(x)`, если при ревью это покажется より разумным — оставлено на усмотрение исполнителя данной задачи, функционально эквивалентно и тесты не отличат один способ от другого.)

Более простой и настоятельно рекомендуемый вариант Step 3 — заменить `_sqrt`/использование на `dart:math`:
```dart
import 'dart:math' as math;
...
  return dot / (math.sqrt(na) * math.sqrt(nb));
```
и удалить функцию `_sqrt` целиком — `dart:math` не является «внешней библиотекой» (это часть Dart SDK), спек имел в виду отсутствие ML-пакетов (tflite и т.п.), не отсутствие стандартной библиотеки. Использовать этот вариант, он проще и надёжнее самодельного Ньютона.

- [ ] **Step 4: Прогнать**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/local_taste_test.dart`
Expected: PASS (все группы: `bytesToVec`, `orderOffline`)

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/core/local_taste.dart apps/mobile/test/local_taste_test.dart
git commit -m "feat(mobile): local_taste.dart — офлайн-ранжировщик радио (cosine, без ML-библиотек)"
```

---

## Task 12: `_radio()` — включение офлайн-фолбэка

**Files:**
- Modify: `apps/mobile/lib/features/player/player_view.dart`
- Test: `apps/mobile/test/player_radio_offline_test.dart`

**Interfaces:**
- Consumes: `orderOffline`/`bytesToVec` (Task 11), `Db.trackVector`/`trackVectorsFor` (Task 8), `Db.kvGet('taste_centroids')` (формат JSON из Task 10, ключ `taste_centroids` со списками base64 `long_term`/`recent`).

- [ ] **Step 1: Написать тест — сетевая ошибка запускает фолбэк, `reordered:false` — нет**

`apps/mobile/test/player_radio_offline_test.dart` (виджет-тест, по образцу `stream_test.dart` — переиспользовать его `_app()`-хелпер стиль, но с собственным фейковым `Api`):
```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:soundflow/app/providers.dart';
import 'package:soundflow/data/api.dart';
import 'package:soundflow/data/db.dart';
import 'package:soundflow/data/downloads_repo.dart';
import 'package:soundflow/data/sync_repo.dart';
import 'package:soundflow/features/player/cover_art.dart';
import 'package:soundflow/features/player/player_controller.dart';
import 'package:soundflow/features/player/player_view.dart';
import 'package:soundflow/main.dart';

class _NetworkDownApi extends Api {
  @override
  Future<({List<String> ids, bool reordered})> streamOrder({
    required String seedId,
    required List<String> candidateIds,
  }) async {
    throw DioException(requestOptions: RequestOptions(path: '/v1/stream/order'));
  }
}

class _NoFingerprintApi extends Api {
  @override
  Future<({List<String> ids, bool reordered})> streamOrder({
    required String seedId,
    required List<String> candidateIds,
  }) async =>
      (ids: candidateIds, reordered: false);
}

Uint8List _vecBytes(List<double> values) {
  final bd = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    bd.setFloat32(i * 4, values[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

Future<Widget> _appWith(Api api, Db db) async {
  final sync = SyncRepo(api, db);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      dbProvider.overrideWithValue(db),
      downloadsProvider.overrideWithValue(DownloadsRepo(api, db, sync)),
      playerProvider.overrideWithValue(PlayerController()),
      syncProvider.overrideWithValue(sync),
    ],
    child: const SoundFlowApp(),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('сеть недоступна + есть локальные отпечатки — фолбэк собирает похожее', (tester) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    await db.upsertDownloaded(DownloadedTrack(id: 'a', title: 'A', artist: 'X', path: '/tmp/a', bytes: 1, addedAt: 1));
    await db.upsertDownloaded(DownloadedTrack(id: 'b', title: 'B', artist: 'Y', path: '/tmp/b', bytes: 1, addedAt: 2));
    await db.setTrackVector('a', _vecBytes([1, 0]));
    await db.setTrackVector('b', _vecBytes([0.9, 0.1]));

    await tester.pumpWidget(await _appWith(_NetworkDownApi(), db));
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Кнопка радио живёт в оверлее _actionsOverlay, который открывается
    // долгим тапом по обложке (player_view.dart:500 `onLongPress: _openMenu`
    // на GestureDetector внутри _coverArea; сам пункт меню — Text('радио\nпо
    // этой'), player_view.dart:731) — не отдельная кнопка с тултипом.
    await tester.longPress(find.byType(CoverArt));
    await tester.pump();
    await tester.tap(find.text('радио\nпо этой'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Сервера нет'), findsOneWidget);
    await db.close();
  });

  testWidgets('нет отпечатка у seed (reordered:false) — фолбэк НЕ включается, обычный тост', (tester) async {
    final db = await Db.open(path: inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    await db.upsertDownloaded(DownloadedTrack(id: 'a', title: 'A', artist: 'X', path: '/tmp/a', bytes: 1, addedAt: 1));
    await db.upsertDownloaded(DownloadedTrack(id: 'b', title: 'B', artist: 'Y', path: '/tmp/b', bytes: 1, addedAt: 2));

    await tester.pumpWidget(await _appWith(_NoFingerprintApi(), db));
    await tester.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.longPress(find.byType(CoverArt));
    await tester.pump();
    await tester.tap(find.text('радио\nпо этой'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('нет звукового отпечатка'), findsOneWidget);
    await db.close();
  });
}
```
- [ ] **Step 2: Запустить — падает (фолбэка ещё нет)**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/player_radio_offline_test.dart`
Expected: FAIL

- [ ] **Step 3: Реализовать фолбэк в `_radio()`**

`apps/mobile/lib/features/player/player_view.dart`, импорты в начало файла — добавить:
```dart
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/local_taste.dart';
```
(Проверить, что `dio`/`dart:convert` ещё не импортированы в файле — не дублировать.)

Переписать `_radio()` (строки 294-332):
```dart
  Future<void> _radio(NowPlaying now) async {
    if (_p.radio.value) {
      await _p.stopRadio();
      _toast('Радио выключил');
      return;
    }
    final all = await ref.read(downloadsProvider).list();
    if (all.length < 2) return;
    final ids = [
      for (final t in all)
        if (t.id != now.id) t.id,
    ];
    try {
      final res = await ref
          .read(apiProvider)
          .streamOrder(seedId: now.id, candidateIds: ids);
      if (!res.reordered) {
        _toast('У этой песни нет звукового отпечатка — похожее не подобрать');
        return;
      }
      final byId = {for (final t in all) t.id: t};
      final tail = <NowPlaying>[
        for (final id in res.ids)
          if (byId[id] case final t?)
            NowPlaying(
              id: t.id,
              title: t.title,
              artist: t.artist,
              path: t.path,
              coverPath: t.coverPath,
            ),
      ];
      if (tail.isEmpty || !mounted) return;
      await _p.setSimilarTail(tail);
      _toast('Дальше — похожее по звуку');
    } on DioException catch (_) {
      // именно сетевая ошибка (сервер недоступен) — пробуем локальный
      // фолбэк по уже скачанным трекам; reordered:false (ветка выше) сюда
      // не попадает — источник отпечатка у seed один и тот же что для
      // сервера, что локально, так что фолбэк там всё равно не поможет.
      final tail = await _offlineRadioFallback(now, all);
      if (tail != null && mounted) {
        await _p.setSimilarTail(tail);
        _toast('Сервера нет — собрал похожее из уже скачанного');
        return;
      }
      _toast('Сервер не ответил — радио не собралось');
    } catch (_) {
      _toast('Сервер не ответил — радио не собралось');
    }
  }

  /// Локальный фолбэк, когда сервер недоступен: сравнивает уже скачанные
  /// треки по кэшированным отпечаткам (docs/superpowers/specs/
  /// 2026-09-13-taste-layers-offline-design.md §4.5-4.6). Нет отпечатка у
  /// seed или меньше 2 кандидатов с отпечатками — null (обычный тост
  /// «радио не собралось» тогда и должен показаться — например, на очень
  /// старых скачиваниях до бэкфилла).
  Future<List<NowPlaying>?> _offlineRadioFallback(
    NowPlaying now, List<DownloadedTrack> all) async {
    final db = ref.read(dbProvider);
    final seedBytes = await db.trackVector(now.id);
    final seedVec = seedBytes == null ? null : bytesToVec(seedBytes);
    if (seedVec == null) return null;

    final others = [for (final t in all) if (t.id != now.id) t];
    final rawVecs = await db.trackVectorsFor([for (final t in others) t.id]);
    final candidateVecs = <String, Float32List>{};
    for (final entry in rawVecs.entries) {
      final v = bytesToVec(entry.value);
      if (v != null) candidateVecs[entry.key] = v;
    }
    if (candidateVecs.length < 2) return null;

    final centroidsJson = await db.kvGet('taste_centroids');
    var longTerm = const <Float32List>[];
    var recent = const <Float32List>[];
    if (centroidsJson != null) {
      final data = jsonDecode(centroidsJson) as Map<String, dynamic>;
      Float32List? decode(String b64) => bytesToVec(base64Decode(b64));
      longTerm = [
        for (final b in (data['long_term'] as List? ?? const []))
          if (decode('$b') case final v?) v,
      ];
      recent = [
        for (final b in (data['recent'] as List? ?? const []))
          if (decode('$b') case final v?) v,
      ];
    }

    final byId = {for (final t in others) t.id: t};
    final orderedIds = orderOffline(
      seedVec: seedVec,
      candidateVecs: candidateVecs,
      candidateArtists: {for (final t in others) t.id: t.artist},
      centroidsLongTerm: longTerm,
      centroidsRecent: recent,
    );
    return [
      for (final id in orderedIds)
        if (byId[id] case final t?)
          NowPlaying(id: t.id, title: t.title, artist: t.artist, path: t.path, coverPath: t.coverPath),
    ];
  }
```
(`ref.read(dbProvider)` — `dbProvider` уже существует: `apps/mobile/lib/app/providers.dart:30-31`, `final dbProvider = Provider<Db>((ref) => _missing('dbProvider'));`, переопределяется в тестах через `ProviderScope.overrides` — добавить `dbProvider.overrideWithValue(db)` в `_appWith()` в тестовом файле этой задачи, иначе `_missing('dbProvider')` бросит исключение при вызове `ref.read(dbProvider)` в виджет-тесте.)

- [ ] **Step 4: Прогнать тесты, поправить финдеры/имя провайдера по месту**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test test/player_radio_offline_test.dart`
Expected: PASS — после того, как по месту поправлены (а) финдер кнопки радио под реальную разметку `player_view.dart`, (б) имя провайдера `Db` под реальное содержимое `app/providers.dart`.

- [ ] **Step 5: Прогнать весь набор телефона**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter test`
Expected: PASS (весь набор)

- [ ] **Step 6: `flutter analyze` — чисто**

Run: `export PATH="/e/flutter/bin:$PATH" && cd apps/mobile && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add apps/mobile/lib/features/player/player_view.dart apps/mobile/lib/app/providers.dart apps/mobile/test/player_radio_offline_test.dart
git commit -m "feat(mobile): офлайн-фолбэк радио при недоступности сервера (по уже скачанным трекам)"
```

---

## Task 13: Антипузырь — динамический порог вместо фиксированного 0.4

**Добавлено 13.09.2026** — не было в первой версии плана. Task 4
(гистограмма) на реальной библиотеке Alex (`SOUNDFLOW_LAB_DB`) показала: из
2000 треков ни один не набрал `aff < 0.5`, 60.5% лежат в 0.8-0.9. Порог
антипузыря `aff < 0.4` (`radio.go`, было на строке ~114 до Task 5, ищи
`c.aff < 0.4` рядом с комментарием «антипузырь») на реальных данных
никогда не срабатывает — механизм «раз в 8 слотов — что-то далёкое от
вкуса» на практике тихо не работает вообще. Так было и до этой сессии, не
регрессия — просто раньше это не проверяли на цифрах.

Причина: эмбеддинги PANNs CNN14 неотрицательные, из-за чего косинусные
близости сжаты в узкий верхний диапазон (0.5-1.0 у Alex) — фиксированное
число 0.4, подобранное «на глаз», не соответствует реальной шкале. Смена
модели отпечатков в будущем сдвинула бы шкалу ещё раз, и фиксированное
число снова разошлось бы с реальностью — поэтому чинить нужно не подбором
новой константы, а переходом на процентиль от РЕАЛЬНОГО набора кандидатов
в каждом конкретном вызове (самокалибрующийся порог, не зависит от модели
и не протухает).

**Files:**
- Modify: `apps/server/internal/localdb/radio.go`
- Test: `apps/server/internal/localdb/radio_test.go`

**Interfaces:**
- Consumes: `cs []radioCand` (уже вычислен к этому месту функции).
- Produces: замена условия `c.aff < 0.4` на `c.aff < farThreshold(cs)` — новая
  функция `farThreshold(cs []radioCand) float64`.

- [ ] **Step 1: Написать тест на процентильный порог**

Добавить в `apps/server/internal/localdb/radio_test.go`:
```go
func TestFarThresholdAdaptsToRealDistribution(t *testing.T) {
	// имитация «сжатой» реальной шкалы (0.5..0.95) — фиксированный 0.4
	// не отсекает никого, процентильный обязан отсечь заметную долю
	cs := make([]radioCand, 20)
	for i := range cs {
		cs[i] = radioCand{id: "t" + itoa(i), aff: 0.5 + float64(i)*0.02}
	}
	th := farThreshold(cs)
	if th < 0.4 {
		t.Fatalf("threshold %.3f too low for a compressed 0.5..0.95 distribution", th)
	}
	far := 0
	for _, c := range cs {
		if c.aff < th {
			far++
		}
	}
	if far == 0 {
		t.Error("expected the threshold to actually select some candidates as «far» on this distribution")
	}
	if far == len(cs) {
		t.Error("threshold should not select ALL candidates as «far»")
	}
}

func TestFarThresholdEmptyInput(t *testing.T) {
	if th := farThreshold(nil); th != 0 {
		t.Errorf("empty input should give threshold 0 (nobody qualifies as far), got %v", th)
	}
}
```

- [ ] **Step 2: Запустить — падает, функции нет**

Run: `cd apps/server && go test ./internal/localdb/... -run TestFarThreshold -v`
Expected: FAIL (`undefined: farThreshold`)

- [ ] **Step 3: Реализовать — 20-й процентиль по aff среди кандидатов**

В `apps/server/internal/localdb/radio.go`, рядом с `const radioSkipDays = 14`
добавить:
```go
// farPercentile — какая доля кандидатов (снизу по aff) считается «далёкой
// от вкуса» для антипузыря. 0.4 — фиксированное число не подходит: реальные
// эмбеддинги (PANNs CNN14) дают косинусы, сжатые в узкий верхний диапазон
// (проверено на soundflow-lab.db 13.09.2026 — 0% ниже 0.5), так что абсолютный
// порог 0.4 никогда не срабатывал. Процентиль самокалибруется под любую
// реальную шкалу и не протухает при смене модели отпечатков.
const farPercentile = 0.20

// farThreshold — порог aff, ниже которого кандидат идёт в антипузырь:
// нижние farPercentile от текущего набора кандидатов. Пусто → 0 (никого
// не выбрать, антипузырь молча выключен — как было раньше при пустых cs).
func farThreshold(cs []radioCand) float64 {
	if len(cs) == 0 {
		return 0
	}
	affs := make([]float64, len(cs))
	for i, c := range cs {
		affs[i] = c.aff
	}
	sort.Float64s(affs)
	idx := int(float64(len(affs)) * farPercentile)
	if idx >= len(affs) {
		idx = len(affs) - 1
	}
	return affs[idx]
}
```
Заменить условие сборки `far` (было `if c.aff < 0.4`):
```go
	// антипузырь: отдельная очередь «далеко от вкуса», по близости к seed
	threshold := farThreshold(cs)
	var far []radioCand
	for _, c := range cs {
		if c.aff < threshold {
			far = append(far, c)
		}
	}
```
(`"sort"` уже импортирован в файле.)

- [ ] **Step 4: Прогнать новые тесты**

Run: `cd apps/server && go test ./internal/localdb/... -run TestFarThreshold -v`
Expected: PASS

- [ ] **Step 5: Прогнать весь пакет — существующие тесты на антипузырь/дубли не должны сломаться**

Run: `cd apps/server && go test ./... -v`
Expected: PASS, включая `TestOrderRadioTasteAware` и `TestOrderRadioNoDuplicatesNoDrops` (Task 5) — на их синтетических данных (одна ось 0, одна ось 700, косинус ровно 0 или ~1) процентиль 20% должен по-прежнему выделять «far»-треки корректно, но проверить именно прогоном, не предполагать.

- [ ] **Step 6: Проверить на реальной библиотеке — сколько теперь реально попадает в антипузырь**

Run: `cd apps/server && SOUNDFLOW_LAB_DB="E:/soundflow-lab/soundflow.db" go test ./internal/localdb/... -run TestTasteHistogramReport -v`
(Гистограмма не проверяет сам `farThreshold`, но даёт понять реальный разброс — если 20-й процентиль совпадёт с ожиданиями по гистограмме, порог адекватен. При сомнении — обсудить с Alex перед коммитом, не менять `farPercentile` без обсуждения.)

- [ ] **Step 7: Commit**

```bash
git add apps/server/internal/localdb/radio.go apps/server/internal/localdb/radio_test.go
git commit -m "fix(server): антипузырь — процентильный порог вместо мёртвого фиксированного 0.4"
```

---

## После всех задач

- Прогнать `go test ./...` (apps/server) и `flutter test` (apps/mobile) — оба зелёные (кроме предсуществующего известного сбоя `search_test.dart`, если он есть — не относится к этой работе).
- Обновить `docs/PROGRESS.md` — новый этап (67 или следующий по счёту), с честной пометкой: серверная часть можно проверить на реальной базе (`SOUNDFLOW_LAB_DB`, Task 4), а офлайн-фолбэк на телефоне по своей природе проверяется ТОЛЬКО руками на реальном устройстве с выключенным сервером — «не проверено на устройстве», пока Alex сам не попробует (выключить Wi-Fi/сервер, нажать «Радио» на скачанной песне).
- Сборка APK — только по прямой просьбе Alex, после того как он увидит текстовый отчёт о готовности через Telegram.
- Отчитаться Alex-у в Telegram простым языком: что изменилось (радио теперь смотрит на «долгий», «недавний» и «прямо сейчас» вкус; без сервера радио само собирает похожее из скачанного), что ещё НЕ проверено на телефоне.
