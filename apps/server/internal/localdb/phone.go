package localdb

import (
	"encoding/json"
	"errors"
	"time"
)

// Методы под телефонный HTTP-API (тот же контракт, что у db.Pool, но локально).

// NextLibraryBatch — следующая порция «докачать ещё N байт»: треки не из
// excludeIDs, сначала избранные (legacy_marks favorite), затем по порядку
// добавления; набираем пока не превысим budgetBytes. Не отдаём live-записи и
// обрезки < 40 с (как в Postgres-версии).
func (d *DB) NextLibraryBatch(excludeIDs []string, budgetBytes int64) ([]CatalogTrack, int64, error) {
	ex := map[string]bool{}
	for _, id := range excludeIDs {
		ex[id] = true
	}
	rows, err := d.sql.Query(catalogSelect + `
		AND t.release_kind <> 'live'
		AND COALESCE(tf.duration_sec, t.duration_sec, 120) >= 40
		ORDER BY favorite DESC, t.created_at ASC
		LIMIT 8000`)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := make([]CatalogTrack, 0)
	var total int64
	for rows.Next() {
		var t CatalogTrack
		if err := rows.Scan(&t.ID, &t.Artist, &t.Title, &t.Album, &t.DurationSec,
			&t.ReleaseKind, &t.Explicit, &t.CoverURL, &t.Favorite,
			&t.SizeBytes, &t.BitrateKbps, &t.MimeType); err != nil {
			return nil, 0, err
		}
		if ex[t.ID] {
			continue
		}
		if len(out) > 0 && total >= budgetBytes {
			break
		}
		out = append(out, t)
		total += t.SizeBytes
	}
	return out, total, rows.Err()
}

// SyncEvent — одно событие из очереди телефона.
type SyncEvent struct {
	UUID     string          `json:"uuid"`
	Kind     string          `json:"kind"`
	TrackID  string          `json:"track_id"`
	Payload  json.RawMessage `json:"payload"`
	ClientTS int64           `json:"ts"`
}

// Device — телефон, приславший события.
type Device struct {
	ID         string
	Name       string
	AppVersion string
	MusicBytes int64
}

// SaveSync — обновить устройство + вставить новые события (дедуп по uuid).
// Возвращает uuid действительно новых.
func (d *DB) SaveSync(dev Device, events []SyncEvent) ([]string, error) {
	tx, err := d.sql.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback() //nolint:errcheck

	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.Exec(`
		INSERT INTO devices (id,name,app_version,music_bytes,last_sync_at,created_at)
		VALUES (?,?,?,?,?,?)
		ON CONFLICT(id) DO UPDATE SET
			name=excluded.name, app_version=excluded.app_version,
			music_bytes=excluded.music_bytes, last_sync_at=excluded.last_sync_at`,
		dev.ID, dev.Name, dev.AppVersion, dev.MusicBytes, now, now); err != nil {
		return nil, err
	}
	accepted := make([]string, 0, len(events))
	for _, e := range events {
		payload := string(e.Payload)
		if payload == "" {
			payload = "{}"
		}
		res, err := tx.Exec(`
			INSERT INTO sync_events (event_uuid,device_id,kind,track_id,payload,client_ts,applied_at)
			VALUES (?,?,?,?,?,?,?)
			ON CONFLICT(event_uuid) DO NOTHING`,
			e.UUID, dev.ID, e.Kind, e.TrackID, payload, e.ClientTS, now)
		if err != nil {
			return nil, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			accepted = append(accepted, e.UUID)
			// play/like/delete в общий журнал не пишем — только blocked через delete
			if e.Kind == "delete" && e.TrackID != "" {
				_, _ = tx.Exec(`
					INSERT INTO legacy_marks (normalized_key,kind,artist,title,marked_at)
					SELECT t.normalized_key,'blocked',t.artist,t.title,?
					FROM tracks t WHERE t.id = ?
					ON CONFLICT(normalized_key) DO UPDATE SET kind='blocked'`, now, e.TrackID)
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return accepted, nil
}

// SyncReport — когда синхронились и сколько событий принято с телефона.
func (d *DB) SyncReport(deviceID string) (last *time.Time, total int64, err error) {
	var ls string
	e := d.sql.QueryRow(`
		SELECT COALESCE((SELECT last_sync_at FROM devices WHERE id=?),''),
		       (SELECT count(*) FROM sync_events WHERE device_id=?)`,
		deviceID, deviceID).Scan(&ls, &total)
	if errors.Is(e, nil) && ls != "" {
		if tt, pe := time.Parse(time.RFC3339Nano, ls); pe == nil {
			last = &tt
		} else if tt, pe := time.Parse(time.RFC3339, ls); pe == nil {
			last = &tt
		}
	}
	return last, total, e
}

// TrackCoverURL — cover_url трека (может быть меткой embedded/none).
func (d *DB) TrackCoverURL(id string) (url string, found bool, err error) {
	e := d.sql.QueryRow(`SELECT cover_url FROM tracks WHERE id=?`, id).Scan(&url)
	if e != nil {
		return "", false, e
	}
	return url, url != "", nil
}

// CandidateIDsAll — все id треков с отпечатком (пул для радио, когда телефон
// прислал только seed).
func (d *DB) CandidateIDsAll(limit int) ([]string, error) {
	q := `SELECT id FROM tracks WHERE feature_vector IS NOT NULL`
	rows, err := d.sql.Query(q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
		if limit > 0 && len(out) >= limit {
			break
		}
	}
	return out, rows.Err()
}
