package localdb

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

// Контекстное меню окна (Alex TG 20039–20045, 19.09.2026): «добавить/убрать на
// телефоне» одной песни или папки. Здесь — то, что нужно базе для этого.

// pcRemovedReason — причина события delete, когда песню убрали с телефона из
// окна ПК (а не сам телефон). Такое событие НЕ ставит метку «больше не качать»
// (в отличие от SaveSync с телефона) и не попадает в «вкус»: песня остаётся в
// каталоге на компьютере, просто её нет на телефоне.
const pcRemovedReason = "pc_removed"

// LatestDevice — устройство, которое заходило последним (у Alex в списке две
// записи «Samsung»: старая от 08.09 и живая). ok=false — устройств нет.
func (d *DB) LatestDevice() (id, name, lastSync string, ok bool, err error) {
	var ls sql.NullString
	err = d.sql.QueryRow(`
		SELECT id, name, last_sync_at FROM devices
		ORDER BY COALESCE(last_sync_at,'') DESC, created_at DESC LIMIT 1`).Scan(&id, &name, &ls)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", "", false, nil
	}
	if err != nil {
		return "", "", "", false, err
	}
	return id, name, ls.String, true, nil
}

// MergePlan — ДОПОЛНИТЬ план устройства, не затирая то, что в нём уже есть
// (SavePlan заменяет план целиком — для меню это опасно: в плане может лежать
// чужой невыполненный список). Песня из add уходит из remove и наоборот:
// последнее решение побеждает. Возвращает, сколько теперь в плане.
func (d *DB) MergePlan(deviceID string, addIDs, removeIDs []string) (add, remove int, err error) {
	tx, err := d.sql.Begin()
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback() //nolint:errcheck

	var a, r string
	e := tx.QueryRow(`SELECT add_ids, remove_ids FROM sync_plans WHERE device_id=?`, deviceID).Scan(&a, &r)
	if e != nil && !errors.Is(e, sql.ErrNoRows) {
		return 0, 0, e
	}
	var curAdd, curRemove []string
	_ = json.Unmarshal([]byte(a), &curAdd)
	_ = json.Unmarshal([]byte(r), &curRemove)

	inAdd := toSet(curAdd)
	inRemove := toSet(curRemove)
	for _, id := range addIDs {
		if id == "" {
			continue
		}
		delete(inRemove, id)
		inAdd[id] = true
	}
	for _, id := range removeIDs {
		if id == "" {
			continue
		}
		delete(inAdd, id)
		inRemove[id] = true
	}
	// порядок: сначала то, что уже было (по порядку), потом новое — план читается человеком в логах
	newAdd := orderedUnion(curAdd, addIDs, inAdd)
	newRemove := orderedUnion(curRemove, removeIDs, inRemove)
	ab, _ := json.Marshal(newAdd)
	rb, _ := json.Marshal(newRemove)
	if _, err := tx.Exec(`
		INSERT INTO sync_plans (device_id, add_ids, remove_ids, created_at)
		VALUES (?,?,?,?)
		ON CONFLICT(device_id) DO UPDATE SET add_ids=excluded.add_ids,
			remove_ids=excluded.remove_ids, created_at=excluded.created_at`,
		deviceID, string(ab), string(rb), time.Now().UTC().Format(time.RFC3339)); err != nil {
		return 0, 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, err
	}
	return len(newAdd), len(newRemove), nil
}

func toSet(ids []string) map[string]bool {
	m := make(map[string]bool, len(ids))
	for _, id := range ids {
		if id != "" {
			m[id] = true
		}
	}
	return m
}

// orderedUnion — id из old, затем из fresh, но только те, что остались в keep (без повторов).
func orderedUnion(old, fresh []string, keep map[string]bool) []string {
	out := make([]string, 0, len(keep))
	seen := make(map[string]bool, len(keep))
	for _, list := range [][]string{old, fresh} {
		for _, id := range list {
			if id != "" && keep[id] && !seen[id] {
				seen[id] = true
				out = append(out, id)
			}
		}
	}
	return out
}

func newEventUUID(prefix string) string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return prefix + hex.EncodeToString(b)
}

// recordDeviceRemovals — записать «песня убрана с телефона» (событие delete с
// причиной pc_removed). Без метки blocked и без сигнала «вкуса».
func recordDeviceRemovals(tx *sql.Tx, deviceID string, ids []string) error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	for _, id := range ids {
		if id == "" {
			continue
		}
		if _, err := tx.Exec(`
			INSERT INTO sync_events (event_uuid,device_id,kind,track_id,payload,client_ts,applied_at)
			VALUES (?,?,?,?,?,?,?)`,
			newEventUUID("pc-"), deviceID, "delete", id, `{"reason":"`+pcRemovedReason+`"}`,
			time.Now().UnixMilli(), now); err != nil {
			return err
		}
	}
	return nil
}

// pcRemovedIDs — песни, которые Alex убрал с телефона из окна ПК и которые с
// тех пор не скачивались снова. «Докачать ещё» на телефоне не должно их
// возвращать (иначе «убрать с телефона» отменяется первой же докачкой).
func (d *DB) pcRemovedIDs() (map[string]bool, error) {
	rows, err := d.sql.Query(`
		SELECT track_id FROM sync_events
		WHERE kind IN ('download','delete') AND track_id <> ''
		GROUP BY track_id
		HAVING COALESCE(MAX(CASE WHEN kind='delete' AND payload LIKE '%` + pcRemovedReason + `%' THEN applied_at END),'')
		     > COALESCE(MAX(CASE WHEN kind='download' THEN applied_at END),'')`)
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
