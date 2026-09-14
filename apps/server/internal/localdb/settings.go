package localdb

import "time"

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

// BlockedMark — трек в чёрный список (тот же механизм, что для «Удалить
// навсегда» на телефоне, см. phone.go, kind='blocked' в legacy_marks).
type BlockedMark struct {
	NormalizedKey, Artist, Title string
}

// ImportBlocked — помечает blocked пачкой (Alex TG 14.09.2026: дизлайки из
// Яндекса — чтобы не предлагать похожее на то, что он явно не любит).
// blocked побеждает favorite при совпадении ключа — тот же порядок, что и
// везде в проекте (internal/legacy).
func (d *DB) ImportBlocked(items []BlockedMark) (int, error) {
	now := time.Now().UTC().Format(time.RFC3339)
	n := 0
	for _, it := range items {
		if it.NormalizedKey == "" {
			continue
		}
		_, err := d.sql.Exec(`
			INSERT INTO legacy_marks (normalized_key,kind,artist,title,marked_at)
			VALUES (?,'blocked',?,?,?)
			ON CONFLICT(normalized_key) DO UPDATE SET kind='blocked'`,
			it.NormalizedKey, it.Artist, it.Title, now)
		if err != nil {
			return n, err
		}
		n++
	}
	return n, nil
}

// IsBlocked — стоит ли на artist+title чёрная метка (legacy_marks kind =
// 'blocked'). Для фильтра кандидатов «Волны» (Alex TG 14.09.2026) — не
// предлагать то, что уже явно не понравилось (старый чёрный список +
// дизлайки Яндекса, см. ImportBlocked).
func (d *DB) IsBlocked(normalizedKey string) (bool, error) {
	var kind string
	err := d.sql.QueryRow(`SELECT kind FROM legacy_marks WHERE normalized_key = ?`, normalizedKey).Scan(&kind)
	if err != nil {
		return false, nil //nolint:nilerr // нет строки — не заблокирован, не ошибка
	}
	return kind == "blocked", nil
}

// ArtistFeedbackScores — сумма value из feedback_event по артисту (лайк +1,
// дизлайк/скип-сразу -0.7 и т.д., см. internal/localdb/taste.go). Тот же
// запрос, что в taste_suggest.go SuggestDownloads — вынесен сюда отдельным
// методом, чтобы «Волна» могла им воспользоваться, не трогая проверенный код.
func (d *DB) ArtistFeedbackScores() (map[string]float64, error) {
	out := map[string]float64{}
	rows, err := d.sql.Query(`SELECT artist, SUM(value) FROM feedback_event WHERE artist <> '' GROUP BY artist`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var a string
		var s float64
		if err := rows.Scan(&a, &s); err != nil {
			return nil, err
		}
		out[a] = s
	}
	return out, rows.Err()
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
