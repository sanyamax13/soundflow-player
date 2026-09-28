package localdb

import "time"

// TrackName — песня каталога для сопоставления с чужими списками (начальный вкус, tasteseed.go).
type TrackName struct {
	ID, Artist, Title string
}

// TrackNames — все песни каталога: id, исполнитель, название.
func (d *DB) TrackNames() ([]TrackName, error) {
	rows, err := d.sql.Query(`SELECT id, artist, title FROM tracks`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TrackName
	for rows.Next() {
		var t TrackName
		if err := rows.Scan(&t.ID, &t.Artist, &t.Title); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// SeedLikes — отметить песни лайком из внешнего источника (source, напр. "yandex"): обычное событие
// вкуса «like» (+5), по одному на песню и источник — повторный вызов ничего не удваивает.
// Возвращает, сколько лайков добавлено впервые.
func (d *DB) SeedLikes(trackIDs []string, source string) (int, error) {
	tx, err := d.sql.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback() //nolint:errcheck
	var before int
	_ = tx.QueryRow(`SELECT COUNT(*) FROM feedback_event WHERE device_id = ?`, source).Scan(&before)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	for _, id := range trackIDs {
		recordFeedback(tx, source+"-like-"+id, source, id, "like", nil, now, 0)
	}
	var after int
	_ = tx.QueryRow(`SELECT COUNT(*) FROM feedback_event WHERE device_id = ?`, source).Scan(&after)
	return after - before, tx.Commit()
}
