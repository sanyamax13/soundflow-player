package localdb

import (
	"database/sql"
	"time"
)

// Данные для «сторожа по звуку» (internal/tasteguard, cmd/soundflow/dislikeguard.go): что каждая песня с отпечатком
// значит для вкуса и отпечатки кандидатов «Волны», чтобы не качать один и тот же отрывок дважды.

// TrainingRow — песня с отпечатком и всем, по чему решается, нравится она или нет.
type TrainingRow struct {
	TrackID  string
	Vec      []float32
	Path     string  // путь основного файла как в каталоге ('' — файла в каталоге нет)
	Mark     string  // legacy_marks.kind: 'blocked' / 'favorite' / ''
	Feedback float64 // сумма оценок с телефона (лайк +, «не моё» −)
}

// ForEachTrainingRow — построчно (не держа все отпечатки в памяти) отдаёт песни с отпечатком; fn вернул false — стоп.
func (d *DB) ForEachTrainingRow(fn func(TrainingRow) bool) error {
	rows, err := d.sql.Query(`
		SELECT t.id, t.feature_vector,
		       COALESCE((SELECT min(file_path) FROM track_files WHERE track_id = t.id AND rejected = 0), ''),
		       COALESCE((SELECT kind FROM legacy_marks WHERE normalized_key = t.normalized_key), ''),
		       COALESCE((SELECT SUM(value) FROM feedback_event WHERE track_id = t.id), 0)
		FROM tracks t WHERE t.feature_vector IS NOT NULL`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var r TrainingRow
		var blob []byte
		if err := rows.Scan(&r.TrackID, &blob, &r.Path, &r.Mark, &r.Feedback); err != nil {
			return err
		}
		r.Vec = blobToVec(blob)
		if len(r.Vec) == 0 {
			continue
		}
		if !fn(r) {
			break
		}
	}
	return rows.Err()
}

// WaveVector — отпечаток кандидата «Волны» по его id в Яндексе, если уже считали.
func (d *DB) WaveVector(yandexID string) ([]float32, bool, error) {
	var b []byte
	err := d.sql.QueryRow(`SELECT vec FROM wave_vectors WHERE yandex_id = ?`, yandexID).Scan(&b)
	if err == sql.ErrNoRows {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	v := blobToVec(b)
	return v, len(v) > 0, nil
}

// SetWaveVector — запомнить отпечаток кандидата (перезаписывает).
func (d *DB) SetWaveVector(yandexID string, v []float32) error {
	_, err := d.sql.Exec(`INSERT INTO wave_vectors (yandex_id, vec, at) VALUES (?,?,?)
		ON CONFLICT(yandex_id) DO UPDATE SET vec = excluded.vec, at = excluded.at`,
		yandexID, vecToBlob(v), time.Now().UTC().Format(time.RFC3339))
	return err
}

// PruneWaveVectors — выбросить отпечатки кандидатов старше before (кандидаты живут в списках несколько дней).
func (d *DB) PruneWaveVectors(before time.Time) error {
	_, err := d.sql.Exec(`DELETE FROM wave_vectors WHERE at < ?`, before.UTC().Format(time.RFC3339))
	return err
}
