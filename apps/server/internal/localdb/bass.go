package localdb

import (
	"database/sql"
	"errors"
)

// TracksNeedingBass — песни с файлом, не в чёрном списке, у которых удары баса ещё не посчитаны
// (bass_env NULL; не вышло посчитать — пишется пустой срез, чтобы не пытаться на каждом круге).
func (d *DB) TracksNeedingBass(limit int) ([]WaveformCandidate, error) {
	rows, err := d.sql.Query(`
		SELECT t.id, tf.file_path
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		WHERE lm.kind IS NOT 'blocked' AND t.bass_env IS NULL
		GROUP BY t.id
		ORDER BY t.created_at DESC, t.id DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []WaveformCandidate
	for rows.Next() {
		var c WaveformCandidate
		if err := rows.Scan(&c.ID, &c.FilePath); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// SetBass — удары баса трека (20 байт на секунду).
func (d *DB) SetBass(trackID string, b []byte) error {
	_, err := d.sql.Exec(`UPDATE tracks SET bass_env = ? WHERE id = ?`, b, trackID)
	return err
}

// Bass — удары баса трека. found=false — ещё не посчитаны или посчитать не вышло.
func (d *DB) Bass(trackID string) (b []byte, found bool, err error) {
	err = d.sql.QueryRow(`SELECT bass_env FROM tracks WHERE id = ?`, trackID).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return b, len(b) > 0, nil
}
