package localdb

// Громкость песни (интегральная, EBU R128, LUFS) — для выравнивания громкости на телефоне:
// сборники, mp3 и FLAC разных лет звучат на 6–10 дБ по-разному, в машине это самое заметное
// (общий вывод пяти разборов SoundFlow, 26.09.2026). Считает хранитель громкости
// (cmd/soundflow/loudkeeper.go), телефон получает число в /v1/tracks и сам подстраивает звук.
//   NULL            — ещё не считали;
//   LoudnessUnknown — посчитать не вышло (битый/немой файл) — повторно не пытаемся.

const LoudnessUnknown = -99.0

// TracksNeedingLoudness — песни с файлом, не в чёрном списке, у которых громкость ещё не считали.
func (d *DB) TracksNeedingLoudness(limit int) ([]WaveformCandidate, error) {
	rows, err := d.sql.Query(`
		SELECT t.id, tf.file_path
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		WHERE lm.kind IS NOT 'blocked' AND t.loudness_lufs IS NULL
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

// SetLoudness — записать громкость (LoudnessUnknown — не вышло посчитать).
func (d *DB) SetLoudness(id string, lufs float64) error {
	_, err := d.sql.Exec(`UPDATE tracks SET loudness_lufs = ? WHERE id = ?`, lufs, id)
	return err
}

// TrackLoudness — громкость по каждой песне, где она известна.
func (d *DB) TrackLoudness() (map[string]float64, error) {
	rows, err := d.sql.Query(`SELECT id, loudness_lufs FROM tracks WHERE loudness_lufs IS NOT NULL AND loudness_lufs > ?`, LoudnessUnknown)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]float64{}
	for rows.Next() {
		var id string
		var v float64
		if err := rows.Scan(&id, &v); err != nil {
			return nil, err
		}
		out[id] = v
	}
	return out, rows.Err()
}
