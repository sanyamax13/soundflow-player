package localdb

import "time"

// MissingFavorite — трек, залайканный на телефоне, но которого нет (уже
// нет) в текущем каталоге компа. Alex TG 15.09.2026: после чистки каталога
// на телефоне остались старые лайки без файла — хочет, чтобы программа
// сама их нашла и предложила докачать, как лайки Яндекса.
type MissingFavorite struct {
	NormalizedKey string
	Artist        string
	Title         string
}

// ReportMissingFavorites — телефон прислал список залайканных треков;
// сохраняем те, что ещё не встречались (upsert по normalized_key). Что
// делать с ними (уже ли есть в каталоге) решает читающая сторона
// (ListMissingFavorites), чтобы повторный сброс каталога не требовал
// повторной синхронизации телефона.
func (d *DB) ReportMissingFavorites(items []MissingFavorite) error {
	now := time.Now().UTC().Format(time.RFC3339)
	for _, it := range items {
		if it.NormalizedKey == "" {
			continue
		}
		if _, err := d.sql.Exec(`
			INSERT INTO phone_missing_favorites (normalized_key, artist, title, reported_at)
			VALUES (?,?,?,?)
			ON CONFLICT(normalized_key) DO UPDATE SET reported_at=excluded.reported_at`,
			it.NormalizedKey, it.Artist, it.Title, now); err != nil {
			return err
		}
	}
	return nil
}

// ListMissingFavorites — то, что телефон когда-то сообщил как лайк, и чего
// до сих пор нет в каталоге (на случай если трек уже докачали другим
// путём — тогда он тут больше не появится).
func (d *DB) ListMissingFavorites() ([]MissingFavorite, error) {
	rows, err := d.sql.Query(`
		SELECT f.normalized_key, f.artist, f.title
		FROM phone_missing_favorites f
		WHERE NOT EXISTS (SELECT 1 FROM tracks t WHERE t.normalized_key = f.normalized_key)
		ORDER BY f.reported_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []MissingFavorite{}
	for rows.Next() {
		var m MissingFavorite
		if err := rows.Scan(&m.NormalizedKey, &m.Artist, &m.Title); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
