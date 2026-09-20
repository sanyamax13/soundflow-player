package localdb

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

// Возврат песен с телефона на компьютер (Alex TG 20261–20264, 21.09.2026), сторона базы. Состояния строки
// restore_request: wanted — ждём файл с телефона; done — файл вернулся на прежнее место; phone_missing — на телефоне
// этой песни нет; failed — файл пришёл, но не принят (причина в detail).
const (
	RestoreWanted       = "wanted"
	RestoreDone         = "done"
	RestorePhoneMissing = "phone_missing"
	RestoreFailed       = "failed"
)

// RestoreRow — одна песня в списке возврата.
type RestoreRow struct {
	TrackID string `json:"id"`
	FileID  string `json:"-"`
	Path    string `json:"-"` // прежний путь файла на компьютере, как записан в каталоге
	Size    int64  `json:"size_bytes"`
	State   string `json:"state,omitempty"`
	Detail  string `json:"detail,omitempty"`
	Artist  string `json:"artist"`
	Title   string `json:"title"`
}

// restoreEligibility — «стоит ли возвращать эту песню»: на ней НЕ стоит метка «больше не качать» и (при heardOnly) её
// слушали или лайкнули на телефоне (события play / complete / like) либо она в избранном. Смотрит только события и
// метки (они живут по id песни и по её ключу и не пропадают, когда песню убирают из каталога).
func (d *DB) restoreEligibility(heardOnly bool) (func(id, key string) bool, error) {
	marks := map[string]string{}
	rows, err := d.sql.Query(`SELECT normalized_key, kind FROM legacy_marks`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var k, kind string
		if err := rows.Scan(&k, &kind); err != nil {
			rows.Close()
			return nil, err
		}
		marks[k] = kind
	}
	rows.Close()
	heard := map[string]bool{}
	if heardOnly {
		rows, err = d.sql.Query(`SELECT DISTINCT track_id FROM sync_events WHERE kind IN ('play','complete','like') AND track_id <> ''`)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, err
			}
			heard[id] = true
		}
		rows.Close()
	}
	return func(id, key string) bool {
		if marks[key] == "blocked" {
			return false
		}
		return !heardOnly || marks[key] == "favorite" || heard[id]
	}, nil
}

// RestoreEligible — id песен каталога, которые стоит возвращать (см. restoreEligibility). Какие из них «мёртвые» (без
// файла на диске), решает вызывающий код.
func (d *DB) RestoreEligible(heardOnly bool) (map[string]bool, error) {
	ok, err := d.restoreEligibility(heardOnly)
	if err != nil {
		return nil, err
	}
	rows, err := d.sql.Query(`SELECT id, normalized_key FROM tracks`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var id, key string
		if err := rows.Scan(&id, &key); err != nil {
			return nil, err
		}
		if ok(id, key) {
			out[id] = true
		}
	}
	return out, rows.Err()
}

// openBackup — копия базы (VACUUM INTO из программы) только для чтения.
func openBackup(path string) (*sql.DB, error) {
	h, err := sql.Open("sqlite", "file:"+filepath.ToSlash(path)+"?mode=ro")
	if err != nil {
		return nil, err
	}
	var n int
	if err := h.QueryRow(`SELECT COUNT(*) FROM tracks`).Scan(&n); err != nil {
		h.Close()
		return nil, fmt.Errorf("это не копия базы SoundFlow (%s): %w", path, err)
	}
	return h, nil
}

func setOf(d *sql.DB, query string) (map[string]bool, error) {
	rows, err := d.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out[s] = true
	}
	return out, rows.Err()
}

// RestoreBackupCandidates — песни, которых уже нет в каталоге (их убрала «уборка» каталога), но они есть в копии базы
// backupPath: подходящие для возврата (см. restoreEligibility) и с записанным файлом. По одной строке на песню (первый
// принятый файл). Песня, что уже есть в каталоге по id, по ключу или по ключу файла, не попадает.
func (d *DB) RestoreBackupCandidates(backupPath string, heardOnly bool) ([]RestoreRow, error) {
	bk, err := openBackup(backupPath)
	if err != nil {
		return nil, err
	}
	defer bk.Close()
	ok, err := d.restoreEligibility(heardOnly)
	if err != nil {
		return nil, err
	}
	liveIDs, err := setOf(d.sql, `SELECT id FROM tracks`)
	if err != nil {
		return nil, err
	}
	liveKeys, err := setOf(d.sql, `SELECT normalized_key FROM tracks`)
	if err != nil {
		return nil, err
	}
	fileKeys, err := setOf(d.sql, `SELECT normalized_key FROM track_files`)
	if err != nil {
		return nil, err
	}
	rows, err := bk.Query(`
		SELECT t.id, t.normalized_key, tf.id, tf.normalized_key, tf.file_path, COALESCE(tf.size_bytes,0), t.artist, t.title
		FROM tracks t JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		ORDER BY t.id, tf.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []RestoreRow
	seen := map[string]bool{}
	for rows.Next() {
		var r RestoreRow
		var key, fileKey string
		if err := rows.Scan(&r.TrackID, &key, &r.FileID, &fileKey, &r.Path, &r.Size, &r.Artist, &r.Title); err != nil {
			return nil, err
		}
		if seen[r.TrackID] {
			continue
		}
		seen[r.TrackID] = true
		if liveIDs[r.TrackID] || liveKeys[key] || fileKeys[fileKey] || !ok(r.TrackID, key) {
			continue
		}
		r.State = RestoreWanted
		out = append(out, r)
	}
	return out, rows.Err()
}

// RestoreGhosts — вернуть в каталог записи песен (строку песни и строку её файла) из копии базы backupPath: как они
// были до уборки, файла на диске пока нет — он придёт с телефона (restore_request их защищает от новой уборки). Только
// добавляет; то, что уже есть, не трогает. Возвращает, сколько песен вернулось.
func (d *DB) RestoreGhosts(backupPath string, rows []RestoreRow) (int, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	bk, err := openBackup(backupPath)
	if err != nil {
		return 0, err
	}
	defer bk.Close()
	tx, err := d.sql.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	n := 0
	for _, r := range rows {
		c, err := copyRows(tx, bk, "tracks", "id = ?", r.TrackID)
		if err != nil {
			return 0, err
		}
		if c == 0 {
			continue
		}
		if _, err := copyRows(tx, bk, "track_files", "id = ?", r.FileID); err != nil {
			return 0, err
		}
		n++
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return n, nil
}

func columnsOf(q interface {
	Query(string, ...any) (*sql.Rows, error)
}, table string) ([]string, error) {
	rows, err := q.Query(`SELECT name FROM pragma_table_info('` + table + `')`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var cols []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		cols = append(cols, c)
	}
	return cols, rows.Err()
}

// copyRows — строки таблицы table (имя — только константа из кода) с условием where из копии базы в живую (в
// транзакции tx), общими колонками; уже существующие не трогает. Возвращает, сколько строк добавилось.
func copyRows(tx *sql.Tx, bk *sql.DB, table, where string, arg any) (int, error) {
	liveCols, err := columnsOf(tx, table)
	if err != nil {
		return 0, err
	}
	bkCols, err := columnsOf(bk, table)
	if err != nil {
		return 0, err
	}
	have := map[string]bool{}
	for _, c := range bkCols {
		have[c] = true
	}
	var cols []string
	for _, c := range liveCols {
		if have[c] {
			cols = append(cols, c)
		}
	}
	if len(cols) == 0 {
		return 0, fmt.Errorf("в таблице %s нет общих колонок с копией", table)
	}
	rows, err := bk.Query(`SELECT `+strings.Join(cols, ",")+` FROM `+table+` WHERE `+where, arg)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	ins := `INSERT OR IGNORE INTO ` + table + ` (` + strings.Join(cols, ",") + `) VALUES (` +
		strings.TrimSuffix(strings.Repeat("?,", len(cols)), ",") + `)`
	n := 0
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return 0, err
		}
		res, err := tx.Exec(ins, vals...)
		if err != nil {
			return 0, err
		}
		if c, _ := res.RowsAffected(); c > 0 {
			n++
		}
	}
	return n, rows.Err()
}

// AddRestoreRequests — поставить песни в очередь возврата. Уже стоящие в списке (в любом состоянии) не трогает, кроме
// failed: их ставит заново (Alex мог починить причину). Возвращает, сколько строк стало «wanted».
func (d *DB) AddRestoreRequests(rows []RestoreRow) (int, error) {
	tx, err := d.sql.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	now := time.Now().UTC().Format(time.RFC3339)
	added := 0
	for _, r := range rows {
		res, err := tx.Exec(`
			INSERT INTO restore_request (track_id, file_id, path, size_bytes, state, detail, updated_at)
			VALUES (?, ?, ?, ?, 'wanted', '', ?)
			ON CONFLICT(track_id) DO UPDATE SET file_id = excluded.file_id, path = excluded.path,
				size_bytes = excluded.size_bytes, state = 'wanted', detail = '', updated_at = excluded.updated_at
			WHERE restore_request.state = 'failed'`, r.TrackID, r.FileID, r.Path, r.Size, now)
		if err != nil {
			return 0, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			added++
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return added, nil
}

// RestoreWantedIDs — id песен, которые ждут файл с телефона.
func (d *DB) RestoreWantedIDs() (map[string]bool, error) {
	rows, err := d.sql.Query(`SELECT track_id FROM restore_request WHERE state = 'wanted'`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}

// RestoreWantedList — песни, которые ждут файл, с именами (для телефона). Песни, которых уже нет в каталоге
// (записи убрали), в список не попадают.
func (d *DB) RestoreWantedList() ([]RestoreRow, error) {
	rows, err := d.sql.Query(`
		SELECT r.track_id, r.size_bytes, t.artist, t.title
		FROM restore_request r JOIN tracks t ON t.id = r.track_id
		WHERE r.state = 'wanted' ORDER BY t.artist, t.title`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []RestoreRow{}
	for rows.Next() {
		var r RestoreRow
		if err := rows.Scan(&r.TrackID, &r.Size, &r.Artist, &r.Title); err != nil {
			return nil, err
		}
		r.State = RestoreWanted
		out = append(out, r)
	}
	return out, rows.Err()
}

// RestoreByTrack — строка возврата по песне вместе с именем; ok=false — песни нет в списке или уже нет в каталоге.
func (d *DB) RestoreByTrack(id string) (RestoreRow, bool, error) {
	var r RestoreRow
	err := d.sql.QueryRow(`
		SELECT r.track_id, r.file_id, r.path, r.size_bytes, r.state, r.detail, t.artist, t.title
		FROM restore_request r JOIN tracks t ON t.id = r.track_id WHERE r.track_id = ?`, id).
		Scan(&r.TrackID, &r.FileID, &r.Path, &r.Size, &r.State, &r.Detail, &r.Artist, &r.Title)
	if err == sql.ErrNoRows {
		return RestoreRow{}, false, nil
	}
	if err != nil {
		return RestoreRow{}, false, err
	}
	return r, true, nil
}

// SetRestoreState — новое состояние строки; detail — причина (для failed) или пусто.
func (d *DB) SetRestoreState(id, state, detail string) error {
	_, err := d.sql.Exec(`UPDATE restore_request SET state = ?, detail = ?, updated_at = ? WHERE track_id = ?`,
		state, detail, time.Now().UTC().Format(time.RFC3339), id)
	return err
}

// MarkRestorePhoneMissing — телефон сообщил, что этих песен у него нет. Меняет только строки в состоянии wanted.
func (d *DB) MarkRestorePhoneMissing(ids []string) (int, error) {
	tx, err := d.sql.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	now := time.Now().UTC().Format(time.RFC3339)
	n := 0
	for _, id := range ids {
		res, err := tx.Exec(`UPDATE restore_request SET state = 'phone_missing', updated_at = ?
			WHERE track_id = ? AND state = 'wanted'`, now, id)
		if err != nil {
			return 0, err
		}
		if c, _ := res.RowsAffected(); c > 0 {
			n++
		}
	}
	return n, tx.Commit()
}

// CancelRestore — снять очередь: строки wanted удаляются (уже вернувшиеся и «нет на телефоне» остаются как история).
func (d *DB) CancelRestore() (int, error) {
	res, err := d.sql.Exec(`DELETE FROM restore_request WHERE state = 'wanted'`)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// RestoreCounts — сколько строк в каждом состоянии и сколько байт ещё ждёт (по записанному размеру).
func (d *DB) RestoreCounts() (counts map[string]int, wantedBytes int64, err error) {
	counts = map[string]int{}
	rows, err := d.sql.Query(`SELECT state, COUNT(*), COALESCE(SUM(size_bytes),0) FROM restore_request GROUP BY state`)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	for rows.Next() {
		var st string
		var n int
		var b int64
		if err := rows.Scan(&st, &n, &b); err != nil {
			return nil, 0, err
		}
		counts[st] = n
		if st == RestoreWanted {
			wantedBytes = b
		}
	}
	return counts, wantedBytes, rows.Err()
}
