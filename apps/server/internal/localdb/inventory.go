package localdb

import (
	"database/sql"
	"time"
)

// Точный список песен на телефоне (Alex TG 20277–20279, 21.09.2026: «инструмент на постоянку, чтобы сверять базу телефона
// и компьютера, точное количество»). До этого компьютер знал состав телефона только по журналу событий (скачал / стёр) —
// приблизительно: события терялись, а плашки и стирания шли мимо журнала. Теперь телефон сам присылает свой список
// (id и размер каждой скачанной песни), компьютер хранит последний.

// InventoryItem — одна песня на телефоне.
type InventoryItem struct {
	ID    string `json:"id"`
	Bytes int64  `json:"b"`
}

// SavePhoneInventory — заменить список песен телефона целиком (одной транзакцией).
func (d *DB) SavePhoneInventory(deviceID string, items []InventoryItem) error {
	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`DELETE FROM phone_inventory WHERE device_id = ?`, deviceID); err != nil {
		return err
	}
	stmt, err := tx.Prepare(`INSERT OR REPLACE INTO phone_inventory (device_id, track_id, size_bytes) VALUES (?, ?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	var total int64
	count := 0
	seen := map[string]bool{}
	for _, it := range items {
		if it.ID == "" || seen[it.ID] {
			continue
		}
		seen[it.ID] = true
		if _, err := stmt.Exec(deviceID, it.ID, it.Bytes); err != nil {
			return err
		}
		total += it.Bytes
		count++
	}
	if _, err := tx.Exec(`
		INSERT INTO phone_inventory_meta (device_id, at, count, bytes) VALUES (?, ?, ?, ?)
		ON CONFLICT(device_id) DO UPDATE SET at = excluded.at, count = excluded.count, bytes = excluded.bytes`,
		deviceID, time.Now().UTC().Format(time.RFC3339), count, total); err != nil {
		return err
	}
	return tx.Commit()
}

// PhoneInventory — последний присланный телефоном список (id → размер) и когда он пришёл. ok=false — телефон списка
// ещё не присылал.
func (d *DB) PhoneInventory(deviceID string) (items map[string]int64, at string, ok bool, err error) {
	err = d.sql.QueryRow(`SELECT at FROM phone_inventory_meta WHERE device_id = ?`, deviceID).Scan(&at)
	if err == sql.ErrNoRows {
		return nil, "", false, nil
	}
	if err != nil {
		return nil, "", false, err
	}
	rows, err := d.sql.Query(`SELECT track_id, size_bytes FROM phone_inventory WHERE device_id = ?`, deviceID)
	if err != nil {
		return nil, "", false, err
	}
	defer rows.Close()
	items = map[string]int64{}
	for rows.Next() {
		var id string
		var size int64
		if err := rows.Scan(&id, &size); err != nil {
			return nil, "", false, err
		}
		items[id] = size
	}
	return items, at, true, rows.Err()
}

// DeviceExists — есть ли такое устройство в списке (телефон заходил).
func (d *DB) DeviceExists(id string) (bool, error) {
	var n int
	if err := d.sql.QueryRow(`SELECT COUNT(*) FROM devices WHERE id = ?`, id).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

// PCSyncFiles — принятые файлы песен каталога, которые компьютер считает «своими» для сверки с телефоном: все, кроме
// песен с меткой «больше не качать». Есть ли файл на диске, проверяет вызывающий код.
func (d *DB) PCSyncFiles() ([]FileRef, error) {
	rows, err := d.sql.Query(`
		SELECT tf.id, t.id, tf.file_path, COALESCE(tf.size_bytes,0)
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		WHERE COALESCE(lm.kind, '') <> 'blocked'
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

// PCRemovedIDs — песни, которые Alex сам убрал с телефона из окна и которые с тех пор не скачивались снова (сверка
// не должна возвращать их на телефон).
func (d *DB) PCRemovedIDs() (map[string]bool, error) { return d.pcRemovedIDs() }
