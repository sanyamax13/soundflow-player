package localdb

import "strings"

// Метки в tracks.cover_url, которые ставит программа сама (cmd/soundflow/coverkeeper.go):
//
//	''             — обложку ещё не проверяли
//	'embedded'     — вшита в сам файл песни
//	'folder'       — картинка в папке альбома (cover.jpg, folder.jpg…)
//	'found'        — найдена поиском в интернете, лежит в found_covers/<id>.jpg
//	'none@ГГГГ-ММ-ДД' — искали в этот день, не нашли (перепроверим позже — появляются новые
//	                 релизы и источники)
//	'artist'       — обложки песни нет нигде, в found_covers/<id>.jpg фото исполнителя (27.09.2026)
//	'http…'        — старая внешняя ссылка (телефон/сервер редиректят на неё)
//
// Саму обложку отдаёт /v1/cover/<id> по порядку «файл → папка → found → ссылка», метка нужна
// только чтобы не проверять одно и то же по кругу.

// CoverCandidate — песня, у которой нужно проверить/поискать обложку.
type CoverCandidate struct {
	ID       string
	Artist   string
	Title    string
	FilePath string // канонический путь файла (s.localPath переводит в путь на этой машине)
	Marker   string // текущая метка cover_url
}

// TracksNeedingCoverCheck — песни с файлом, не в чёрном списке, у которых обложку ещё не
// проверяли (пустая метка) или искали, но не нашли раньше дня retryBefore (ГГГГ-ММ-ДД). Старые метки
// 'none' без даты (после прошлых догонов) считаем «искали давно». Внешние ссылки (http…) и
// метки «есть обложка» сюда не попадают.
func (d *DB) TracksNeedingCoverCheck(retryBefore string, limit int) ([]CoverCandidate, error) {
	rows, err := d.sql.Query(`
		SELECT t.id, t.artist, t.title, tf.file_path, t.cover_url
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		WHERE lm.kind IS NOT 'blocked'
		  AND (t.cover_url = ''
		       OR t.cover_url = 'none'
		       OR (t.cover_url LIKE 'none@%' AND substr(t.cover_url, 6) < ?))
		GROUP BY t.id
		ORDER BY t.created_at DESC, t.id DESC
		LIMIT ?`, retryBefore, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CoverCandidate
	for rows.Next() {
		var c CoverCandidate
		if err := rows.Scan(&c.ID, &c.Artist, &c.Title, &c.FilePath, &c.Marker); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// SetCoverMarker — записать результат проверки обложки песни (метки — см. выше).
func (d *DB) SetCoverMarker(id, marker string) error {
	_, err := d.sql.Exec(`UPDATE tracks SET cover_url = ? WHERE id = ?`, marker, id)
	return err
}

// ResetCoverMisses — снять все метки «не нашла» (none@дата), чтобы хранитель обложек переспросил эти
// песни на следующем круге. Возвращает, сколько сняла.
func (d *DB) ResetCoverMisses() (int64, error) {
	res, err := d.sql.Exec(`UPDATE tracks SET cover_url = '' WHERE cover_url LIKE 'none@%' OR cover_url = 'none'`)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// CleanArtistNames — прогнать имена исполнителей через clean и записать изменившиеся (вместе с
// search_text для поиска). Возвращает, сколько песен поправила. Сами файлы не трогает.
func (d *DB) CleanArtistNames(clean func(string) string) (int, error) {
	rows, err := d.sql.Query(`SELECT id, artist, title, album FROM tracks`)
	if err != nil {
		return 0, err
	}
	type fix struct{ id, artist, search string }
	var fixes []fix
	for rows.Next() {
		var id, artist, title, album string
		if err := rows.Scan(&id, &artist, &title, &album); err != nil {
			rows.Close()
			return 0, err
		}
		if c := clean(artist); c != artist && c != "" {
			fixes = append(fixes, fix{id, c, strings.ToLower(c + " " + title + " " + album)})
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	for _, f := range fixes {
		if _, err := d.sql.Exec(`UPDATE tracks SET artist = ?, search_text = ? WHERE id = ?`, f.artist, f.search, f.id); err != nil {
			return 0, err
		}
	}
	return len(fixes), nil
}
