package localdb

import "database/sql"

// FileRef — запись о файле каталога, как она лежит в базе (для сверки с диском, см.
// cmd/soundflow/reconcile.go).
type FileRef struct {
	ID      string // track_files.id
	TrackID string // песня (у «хвоста» после удаления песни — id уже несуществующей)
	Path    string
	Size    int64
}

// AllFileRefs — все записи о файлах каталога.
func (d *DB) AllFileRefs() ([]FileRef, error) {
	rows, err := d.sql.Query(`SELECT id, track_id, file_path, COALESCE(size_bytes,0) FROM track_files`)
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

// RemoveFileRecords — убрать из каталога записи о файлах (по id записи файла) и те песни, у которых
// после этого не осталось ни одного файла. Файлы на диске, метки («больше не качать», избранное),
// лайки и события синхронизации НЕ трогает — только строки каталога (как и DeleteTrackByKey). Одной
// транзакцией: сорвалось — не убрано ничего. Возвращает, сколько записей файлов и сколько песен убрано.
func (d *DB) RemoveFileRecords(fileIDs []string) (files, songs int, err error) {
	if len(fileIDs) == 0 {
		return 0, 0, nil
	}
	tx, err := d.sql.Begin()
	if err != nil {
		return 0, 0, err
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()
	touched := map[string]bool{}
	for _, id := range fileIDs {
		var tid sql.NullString
		qerr := tx.QueryRow(`SELECT track_id FROM track_files WHERE id = ?`, id).Scan(&tid)
		if qerr == sql.ErrNoRows {
			continue
		}
		if qerr != nil {
			err = qerr
			return 0, 0, err
		}
		if _, err = tx.Exec(`DELETE FROM track_files WHERE id = ?`, id); err != nil {
			return 0, 0, err
		}
		files++
		if tid.String != "" {
			touched[tid.String] = true
		}
	}
	for tid := range touched {
		var left int
		if err = tx.QueryRow(`SELECT COUNT(*) FROM track_files WHERE track_id = ?`, tid).Scan(&left); err != nil {
			return 0, 0, err
		}
		if left > 0 {
			continue
		}
		res, derr := tx.Exec(`DELETE FROM tracks WHERE id = ?`, tid)
		if derr != nil {
			err = derr
			return 0, 0, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			songs++
		}
	}
	if err = tx.Commit(); err != nil {
		return 0, 0, err
	}
	return files, songs, nil
}

// FileByKey — запись файла песни по её ключу: id записи и путь. ok=false — записи нет.
func (d *DB) FileByKey(normKey string) (id, path string, ok bool, err error) {
	err = d.sql.QueryRow(`SELECT id, file_path FROM track_files WHERE normalized_key = ?`, normKey).Scan(&id, &path)
	if err == sql.ErrNoRows {
		return "", "", false, nil
	}
	if err != nil {
		return "", "", false, err
	}
	return id, path, true, nil
}

// RelinkFile — направить запись файла на новый путь: файл перенесли в другую папку, песня та же (лайки и
// метки остаются при ней).
func (d *DB) RelinkFile(id, newPath string, size int64) error {
	_, err := d.sql.Exec(`UPDATE track_files SET file_path = ?, size_bytes = ? WHERE id = ?`, newPath, size, id)
	return err
}
