package localdb

import (
	"sort"
	"strings"
	"time"
)

// «Центры вкуса» по звуку (TASTE-PLAN §3, этап 3). Кластеризуем отпечатки
// положительно оценённых треков (SUM(value) > 0 в feedback_event). Кандидата
// потом меряем косинусом к БЛИЖАЙШЕМУ центру, не к среднему — у человека
// параллельно несколько жанров, среднее по ним «каша».

const posScoredWithVector = `
	SELECT t.id, t.artist, t.title, fe.s, fe.last_at, t.feature_vector
	FROM tracks t
	JOIN (SELECT track_id, SUM(value) AS s, MAX(created_at) AS last_at
	      FROM feedback_event
	      WHERE track_id <> '' GROUP BY track_id HAVING s > 0) fe ON fe.track_id = t.id
	WHERE t.feature_vector IS NOT NULL
	ORDER BY t.id`

// kFor — сколько центров по числу любимых треков.
func kFor(n int) int {
	switch {
	case n >= 40:
		return 5
	case n >= 15:
		return 4
	default:
		return 3
	}
}

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

// tasteAffinity — близость вектора к вкусу: макс. косинус к ближайшему
// центру, зажат в 0..1. Нет центров / пустой вектор → 0.
func tasteAffinity(cents [][]float32, vec []float32) float64 {
	if len(cents) == 0 || len(vec) == 0 {
		return 0
	}
	nv := l2norm(vec)
	best := -1.0
	for _, c := range cents {
		if len(c) != len(nv) {
			continue
		}
		if s := dotF32(nv, c); s > best {
			best = s
		}
	}
	if best < 0 {
		return 0
	}
	return best
}

// ScoreTracksByTaste — для набора id каталога: близость к вкусу (0..1) по
// ближайшему центру. Нет центров → пустая карта. Основа канала «похожие на
// вкус» в автоподборе (этап 4).
func (d *DB) ScoreTracksByTaste(ids []string) (map[string]float64, error) {
	out := make(map[string]float64, len(ids))
	cents, err := d.tasteCentroidsLayer("long_term")
	if err != nil || len(cents) == 0 {
		return out, err
	}
	const chunk = 900
	for i := 0; i < len(ids); i += chunk {
		end := i + chunk
		if end > len(ids) {
			end = len(ids)
		}
		part := ids[i:end]
		ph := strings.TrimSuffix(strings.Repeat("?,", len(part)), ",")
		args := make([]any, len(part))
		for j, id := range part {
			args[j] = id
		}
		rows, err := d.sql.Query(
			`SELECT id, feature_vector FROM tracks WHERE feature_vector IS NOT NULL AND id IN (`+ph+`)`, args...)
		if err != nil {
			return out, err
		}
		for rows.Next() {
			var id string
			var b []byte
			if err := rows.Scan(&id, &b); err != nil {
				rows.Close()
				return out, err
			}
			out[id] = tasteAffinity(cents, blobToVec(b))
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return out, err
		}
	}
	return out, nil
}

// TasteClusterInfo — кластер вкуса для окна: размер + яркие представители
// (высоко оценённые треки, ближайшие к центру).
type TasteClusterInfo struct {
	Idx       int        `json:"idx"`
	N         int        `json:"n"`
	Exemplars []TasteRow `json:"exemplars"`
}

// TasteClusters — центры вкуса с примерами треков (perCluster на каждый).
func (d *DB) TasteClusters(perCluster int) ([]TasteClusterInfo, error) {
	if perCluster <= 0 {
		perCluster = 4
	}
	cents, err := d.tasteCentroidsLayer("long_term")
	if err != nil || len(cents) == 0 {
		return nil, err
	}
	rows, err := d.sql.Query(posScoredWithVector)
	if err != nil {
		return nil, err
	}
	type scored struct {
		sim float64
		row TasteRow
	}
	buckets := make([][]scored, len(cents))
	for rows.Next() {
		var r TasteRow
		var lastAt string
		var blob []byte
		if err := rows.Scan(&r.ID, &r.Artist, &r.Title, &r.Score, &lastAt, &blob); err != nil {
			rows.Close()
			return nil, err
		}
		v := blobToVec(blob)
		if len(v) == 0 {
			continue
		}
		nv := l2norm(v)
		best, bi := -2.0, 0
		for ci, c := range cents {
			if len(c) != len(nv) {
				continue
			}
			if s := dotF32(nv, c); s > best {
				best, bi = s, ci
			}
		}
		buckets[bi] = append(buckets[bi], scored{best, r})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out := make([]TasteClusterInfo, len(cents))
	for ci := range cents {
		b := buckets[ci]
		sort.Slice(b, func(i, j int) bool { return b[i].sim > b[j].sim })
		info := TasteClusterInfo{Idx: ci, N: len(b)}
		for i := 0; i < perCluster && i < len(b); i++ {
			info.Exemplars = append(info.Exemplars, b[i].row)
		}
		out[ci] = info
	}
	return out, nil
}
