package localdb

import "database/sql"

// BlockedTrackFiles — записи файлов у песен каталога, помеченных «больше не качать» (legacy_marks kind =
// 'blocked'; на один ключ приходится одна метка — «избранное» и «не качать» вместе не бывают). Только принятые
// файлы (rejected = 0). Нужны окну, чтобы показать: пометка есть, а файл лежит на диске (cmd/soundflow/blockedfiles.go).
func (d *DB) BlockedTrackFiles() ([]FileRef, error) {
	rows, err := d.sql.Query(`
		SELECT tf.id, t.id, tf.file_path, COALESCE(tf.size_bytes,0)
		FROM tracks t
		JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key AND lm.kind = 'blocked'
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		ORDER BY t.id, tf.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []FileRef
	for rows.Next() {
		var r FileRef
		var tid sql.NullString
		if err := rows.Scan(&r.ID, &tid, &r.Path, &r.Size); err != nil {
			return nil, err
		}
		r.TrackID = tid.String
		out = append(out, r)
	}
	return out, rows.Err()
}
