package localdb

// SpectrumCandidate — песня, у которой ещё не проверен спектр (cmd/soundflow/spectrumkeeper.go).
type SpectrumCandidate struct {
	ID          string
	FilePath    string // канонический путь (s.localPath переводит в путь на этой машине)
	QualityTier string // текущий tier из track_files — решаем, понижать ли
}

// TracksNeedingSpectrum — песни с файлом, не в чёрном списке, у которых
// spectral_cutoff_hz ещё NULL (SetSpectralCutoff пишет хотя бы 0, даже когда
// определить не вышло, чтобы не пытаться на каждом круге заново). Это же
// покрывает «прогони по всем песням» (Alex TG 24.09.2026) — весь старый
// каталог для этого поля NULL, keeper дойдёт до него пачками.
func (d *DB) TracksNeedingSpectrum(limit int) ([]SpectrumCandidate, error) {
	rows, err := d.sql.Query(`
		SELECT t.id, tf.file_path, tf.quality_tier
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		WHERE lm.kind IS NOT 'blocked' AND t.spectral_cutoff_hz IS NULL
		GROUP BY t.id
		ORDER BY t.created_at DESC, t.id DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SpectrumCandidate
	for rows.Next() {
		var c SpectrumCandidate
		if err := rows.Scan(&c.ID, &c.FilePath, &c.QualityTier); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// TrackFileQualityTier — текущий tier трека (по track_id). Для тестов/отладки.
func (d *DB) TrackFileQualityTier(trackID string) (string, error) {
	var tier string
	err := d.sql.QueryRow(`SELECT quality_tier FROM track_files WHERE track_id = ?`, trackID).Scan(&tier)
	return tier, err
}

// SetSpectralCutoff — записывает частоту среза спектра (Гц, 0 = не
// определили) и, если tier понизился, обновляет track_files.quality_tier.
func (d *DB) SetSpectralCutoff(trackID string, hz int, newTier string, downgraded bool) error {
	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE tracks SET spectral_cutoff_hz = ? WHERE id = ?`, hz, trackID); err != nil {
		return err
	}
	if downgraded {
		if _, err := tx.Exec(`UPDATE track_files SET quality_tier = ? WHERE track_id = ?`, newTier, trackID); err != nil {
			return err
		}
	}
	return tx.Commit()
}
