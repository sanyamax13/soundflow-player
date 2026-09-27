package localdb

import "time"

// Родные обложки для песен из сборников (26.09.2026, Alex TG 21750: «к каждой песне найди обложку
// оригинальную или фанатскую; если в сборниках нет оригинальной — бери основную из сборника»).
// Сборник — папка, где лежат песни трёх и больше разных исполнителей: у таких песен в файле зашита
// обложка сборника, а не своя.

type OrigCoverCandidate struct {
	ID, Artist, Title string
	FilePath, Dir     string
}

const compilationDirs = `
	WITH d AS (
		SELECT t.id, t.artist, t.title, tf.file_path,
		       rtrim(tf.file_path, replace(replace(tf.file_path, '/', ''), '\', '')) AS dir
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
	), comp AS (
		SELECT dir FROM d GROUP BY dir HAVING COUNT(DISTINCT lower(artist)) >= 3
	)`

// TracksNeedingOriginalCover — песни из сборников, для которых родную обложку ещё не искали
// (или не нашли раньше retryBefore, ГГГГ-ММ-ДД).
func (d *DB) TracksNeedingOriginalCover(retryBefore string, limit int) ([]OrigCoverCandidate, error) {
	rows, err := d.sql.Query(compilationDirs+`
		SELECT d.id, d.artist, d.title, d.file_path, d.dir FROM d
		LEFT JOIN track_original_cover o ON o.track_id = d.id
		WHERE d.dir IN (SELECT dir FROM comp)
		  AND (o.track_id IS NULL OR (o.state = 'none' AND substr(o.checked_at, 1, 10) < ?))
		GROUP BY d.id
		LIMIT ?`, retryBefore, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []OrigCoverCandidate
	for rows.Next() {
		var c OrigCoverCandidate
		if err := rows.Scan(&c.ID, &c.Artist, &c.Title, &c.FilePath, &c.Dir); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// SetOriginalCover — отметить результат поиска: found=true — файл уже лежит в original_covers.
func (d *DB) SetOriginalCover(id string, found bool) error {
	state := "none"
	if found {
		state = "found"
	}
	return d.SetOriginalCoverState(id, state)
}

// SetOriginalCoverState — 'found' / 'none' / 'own' (в файле уже СВОЯ обложка, не сборника — не трогаем).
func (d *DB) SetOriginalCoverState(id, state string) error {
	_, err := d.sql.Exec(`
		INSERT INTO track_original_cover (track_id, state, checked_at) VALUES (?, ?, ?)
		ON CONFLICT(track_id) DO UPDATE SET state = excluded.state, checked_at = excluded.checked_at`,
		id, state, time.Now().Format("2006-01-02"))
	return err
}

// OriginalCoverRevs — по каким песням есть родная обложка и когда найдена (метка для телефона:
// поменялась — перекачать обложку).
func (d *DB) OriginalCoverRevs() (map[string]string, error) {
	rows, err := d.sql.Query(`SELECT track_id, checked_at FROM track_original_cover WHERE state = 'found'`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var id, at string
		if err := rows.Scan(&id, &at); err != nil {
			return nil, err
		}
		out[id] = "o" + at
	}
	return out, rows.Err()
}

// ResetOriginalCovers — забыть все результаты (после исправления правил поиска — пройти заново).
func (d *DB) ResetOriginalCovers() error {
	_, err := d.sql.Exec(`DELETE FROM track_original_cover`)
	return err
}

// DirSiblings — все песни той же папки (путь файла и исполнитель): хранителю родных обложек нужно
// считать «одна картинка у 3+ песен 2+ исполнителей» по ВСЕЙ папке, а не только по песням текущего
// прохода (иначе новая песня сборника, пришедшая одна, навсегда получала «своя обложка» — ревизия
// кода 27.09.2026).
func (d *DB) DirSiblings(dir string) ([]OrigCoverCandidate, error) {
	rows, err := d.sql.Query(`
		WITH d AS (
			SELECT t.id, t.artist, t.title, tf.file_path,
			       rtrim(tf.file_path, replace(replace(tf.file_path, '/', ''), '\', '')) AS dir
			FROM tracks t
			JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		)
		SELECT id, artist, title, file_path, dir FROM d WHERE dir = ?`, dir)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []OrigCoverCandidate
	for rows.Next() {
		var c OrigCoverCandidate
		if err := rows.Scan(&c.ID, &c.Artist, &c.Title, &c.FilePath, &c.Dir); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
