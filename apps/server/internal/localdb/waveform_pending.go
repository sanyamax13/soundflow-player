package localdb

// WaveformCandidate — песня, у которой ещё не посчитан рельеф громкости для полоски плеера
// (cmd/soundflow/wavekeeper.go).
type WaveformCandidate struct {
	ID       string
	FilePath string // канонический путь файла (s.localPath переводит в путь на этой машине)
}

// TracksNeedingWaveform — песни с файлом, не в чёрном списке, у которых waveform ещё NULL
// (SetWaveform пишет хотя бы пустой срез — []byte{} — даже когда посчитать не вышло, чтобы не
// пытаться на каждом круге заново).
func (d *DB) TracksNeedingWaveform(limit int) ([]WaveformCandidate, error) {
	rows, err := d.sql.Query(`
		SELECT t.id, tf.file_path
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		WHERE lm.kind IS NOT 'blocked' AND t.waveform IS NULL
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
