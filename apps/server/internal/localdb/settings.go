package localdb

// Мелкие настройки программы — ключ/значение, сейчас только «папка для
// авто-проверки на новые песни» (Alex TG 14.09.2026, см. app_settings в
// миграциях localdb.go).

func (d *DB) GetSetting(key string) (string, bool, error) {
	var v string
	err := d.sql.QueryRow(`SELECT value FROM app_settings WHERE key = ?`, key).Scan(&v)
	if err != nil {
		return "", false, nil //nolint:nilerr // нет строки — не ошибка, просто нет значения
	}
	return v, true, nil
}

func (d *DB) SetSetting(key, value string) error {
	_, err := d.sql.Exec(`INSERT INTO app_settings (key, value) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

// NewSinceItem — трек, добавленный в каталог после какого-то момента —
// для точки «новое» на плитке альбома в окне на компе.
type NewSinceItem struct {
	ID     string `json:"id"`
	Artist string `json:"artist"`
	Title  string `json:"title"`
	Album  string `json:"album"`
}

// TracksCreatedSince — треки с created_at позже since (RFC3339, UTC).
func (d *DB) TracksCreatedSince(since string) ([]NewSinceItem, error) {
	rows, err := d.sql.Query(`SELECT id, artist, title, album FROM tracks
		WHERE created_at > ? ORDER BY created_at`, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []NewSinceItem{}
	for rows.Next() {
		var it NewSinceItem
		if err := rows.Scan(&it.ID, &it.Artist, &it.Title, &it.Album); err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}
