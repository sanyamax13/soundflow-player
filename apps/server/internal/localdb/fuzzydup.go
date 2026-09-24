package localdb

import "soundflow/server/internal/quality"

// FuzzyKnownKeys — quality.FuzzyKey всех треков каталога → их id. Скан вызывает это
// один раз перед обходом папки (как KnownFilePaths), дальше на каждый файл — просто
// проверка по карте: тот же формат «своя песня уже была, просто записана чуть иначе»
// (Alex TG 24.09.2026: «научи программу, чтобы сама определяла дубли»), см.
// quality.FuzzyKey — шире NormalizedKey, ловит «(Album Version)»/«(feat. …)»/
// слипшиеся-разъехавшиеся пробелы в имени.
func (d *DB) FuzzyKnownKeys() (map[string]string, error) {
	rows, err := d.sql.Query(`SELECT id, artist, title FROM tracks`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var id, artist, title string
		if err := rows.Scan(&id, &artist, &title); err != nil {
			return nil, err
		}
		out[quality.FuzzyKey(artist, title)] = id
	}
	return out, rows.Err()
}
