package localdb

import (
	"encoding/binary"
	"encoding/json"
	"math"
	"strings"
)

// Жанр песни (26.09.2026, план Alex «по твоему плану», шаг 4: до этого жанра не было ни у одной из
// 11 632 песен). Хранится в уже существующей колонке tracks.genre_tags (JSON-массив строк):
//   NULL / '' / '[]'  — ещё не спрашивали;
//   '["rusrap"]'      — жанр по Яндексу (код Яндекса);
//   '["-"]'           — спрашивали, Яндекс не знает (повторно не спрашиваем).
// Заполняет хранитель жанров (cmd/soundflow/genrekeeper.go).

const GenreUnknown = "-"

type GenreCandidate struct {
	ID, Artist, Title string
}

// TracksNeedingGenre — песни, у которых жанр ещё не спрашивали (новые сверху).
func (d *DB) TracksNeedingGenre(limit int) ([]GenreCandidate, error) {
	rows, err := d.sql.Query(`
		SELECT id, artist, title FROM tracks
		WHERE genre_tags IS NULL OR genre_tags = '' OR genre_tags = '[]'
		ORDER BY created_at DESC, id DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []GenreCandidate
	for rows.Next() {
		var c GenreCandidate
		if err := rows.Scan(&c.ID, &c.Artist, &c.Title); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// SetGenre — записать жанр ("" → «Яндекс не знает», больше не спрашивать).
func (d *DB) SetGenre(id, genre string) error {
	g := strings.TrimSpace(genre)
	if g == "" {
		g = GenreUnknown
	}
	b, _ := json.Marshal([]string{g})
	_, err := d.sql.Exec(`UPDATE tracks SET genre_tags = ? WHERE id = ?`, string(b), id)
	return err
}

// TrackGenres — жанр по каждой песне, где он известен (для телефона: фильтр радио по жанру).
func (d *DB) TrackGenres() (map[string]string, error) {
	// Жанр Яндекса, а если Яндекс не знает — угаданный по звуку (genre_guess, moodkeeper.go).
	rows, err := d.sql.Query(`SELECT id, CASE WHEN genre_tags = '["-"]' AND COALESCE(genre_guess,'') <> ''
		THEN '["' || genre_guess || '"]' ELSE genre_tags END FROM tracks
		WHERE genre_tags LIKE '["%'`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]string)
	for rows.Next() {
		var id, raw string
		if err := rows.Scan(&id, &raw); err != nil {
			return nil, err
		}
		var tags []string
		if json.Unmarshal([]byte(raw), &tags) != nil || len(tags) == 0 || tags[0] == GenreUnknown || tags[0] == "" {
			continue
		}
		out[id] = tags[0]
	}
	return out, rows.Err()
}

// ---- Настроение и угаданный жанр (27.09.2026, Alex «делай») ----
// tracks.mood — настроение по звуку (радостное/грустное/нежное/энергичное/агрессивное), считает хранитель
// настроения (moodkeeper.go) по уже готовым отпечаткам; tracks.genre_guess — жанр, угаданный по 15 самым
// похожим песням, для тех, чей жанр Яндекс не знает (метка «-»). Настоящий жанр Яндекса главнее.

// VecRow — отпечаток песни и её жанр по Яндексу ("" — не спрашивали, "-" — Яндекс не знает).
type VecRow struct {
	ID, Genre, Guess string
	Vec              []float32
}

func (d *DB) VectorsForMood() ([]VecRow, error) {
	rows, err := d.sql.Query(`SELECT id, COALESCE(genre_tags,''), COALESCE(genre_guess,''), feature_vector FROM tracks WHERE feature_vector IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []VecRow
	for rows.Next() {
		var r VecRow
		var raw string
		var blob []byte
		if err := rows.Scan(&r.ID, &raw, &r.Guess, &blob); err != nil {
			return nil, err
		}
		var tags []string
		if json.Unmarshal([]byte(raw), &tags) == nil && len(tags) > 0 {
			r.Genre = tags[0]
		}
		if len(blob) < 4 {
			continue
		}
		r.Vec = make([]float32, len(blob)/4)
		for i := range r.Vec {
			r.Vec[i] = math.Float32frombits(binary.LittleEndian.Uint32(blob[i*4:]))
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// SetMoods / SetGenreGuesses — записать пачкой в одной транзакции (id → значение).
func (d *DB) SetMoods(m map[string]string) error { return d.setColumn("mood", m) }
func (d *DB) SetGenreGuesses(m map[string]string) error {
	return d.setColumn("genre_guess", m)
}

func (d *DB) setColumn(col string, m map[string]string) error {
	if len(m) == 0 {
		return nil
	}
	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	st, err := tx.Prepare(`UPDATE tracks SET ` + col + ` = ? WHERE id = ?`)
	if err != nil {
		tx.Rollback()
		return err
	}
	for id, v := range m {
		if _, err := st.Exec(v, id); err != nil {
			st.Close()
			tx.Rollback()
			return err
		}
	}
	st.Close()
	return tx.Commit()
}

// TrackMoods — настроение по каждой песне, где оно посчитано.
func (d *DB) TrackMoods() (map[string]string, error) {
	rows, err := d.sql.Query(`SELECT id, mood FROM tracks WHERE mood IS NOT NULL AND mood <> ''`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var id, v string
		if err := rows.Scan(&id, &v); err != nil {
			return nil, err
		}
		out[id] = v
	}
	return out, rows.Err()
}
