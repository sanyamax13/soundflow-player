package db

import (
	"context"
	"time"
)

// AdminStatus — сводка для экрана «Сервер» в приложении.
type AdminStatus struct {
	Tracks        int64            `json:"tracks"`
	TrackFiles    int64            `json:"track_files"`
	EventsTotal   int64            `json:"events_total"`
	EventsByKind  map[string]int64 `json:"events_by_kind"`
	Devices       int64            `json:"devices"`
	Migrations    []string         `json:"migrations"`
	LegacyFavs    int64            `json:"legacy_favs"`
	LegacyBlocked int64            `json:"legacy_blocked"`
}

func (d *Pool) AdminStatus(ctx context.Context) (AdminStatus, error) {
	var st AdminStatus
	if d == nil || d.p == nil {
		return st, errNoDB
	}
	if err := d.p.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM tracks),
		       (SELECT count(*) FROM track_files),
		       (SELECT count(*) FROM sync_events),
		       (SELECT count(*) FROM devices),
		       (SELECT count(*) FROM legacy_marks WHERE kind = 'favorite'),
		       (SELECT count(*) FROM legacy_marks WHERE kind = 'blocked')`,
	).Scan(&st.Tracks, &st.TrackFiles, &st.EventsTotal, &st.Devices, &st.LegacyFavs, &st.LegacyBlocked); err != nil {
		return st, err
	}

	st.EventsByKind = map[string]int64{}
	rows, err := d.p.Query(ctx, `SELECT kind, count(*) FROM sync_events GROUP BY kind ORDER BY kind`)
	if err != nil {
		return st, err
	}
	for rows.Next() {
		var k string
		var n int64
		if err := rows.Scan(&k, &n); err != nil {
			rows.Close()
			return st, err
		}
		st.EventsByKind[k] = n
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return st, err
	}

	mr, err := d.p.Query(ctx, `SELECT version FROM schema_migrations ORDER BY version`)
	if err != nil {
		return st, err
	}
	for mr.Next() {
		var v string
		if err := mr.Scan(&v); err != nil {
			mr.Close()
			return st, err
		}
		st.Migrations = append(st.Migrations, v)
	}
	mr.Close()
	return st, mr.Err()
}

// DeviceInfo — строка реестра устройств.
type DeviceInfo struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	AppVersion string     `json:"app_version"`
	MusicBytes int64      `json:"music_bytes"`
	LastSyncAt *time.Time `json:"last_sync_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
}

func (d *Pool) ListDevices(ctx context.Context) ([]DeviceInfo, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	rows, err := d.p.Query(ctx, `
		SELECT id, name, app_version, music_bytes, last_sync_at, created_at
		FROM devices ORDER BY last_sync_at DESC NULLS LAST`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]DeviceInfo, 0)
	for rows.Next() {
		var di DeviceInfo
		if err := rows.Scan(&di.ID, &di.Name, &di.AppVersion, &di.MusicBytes, &di.LastSyncAt, &di.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, di)
	}
	return out, rows.Err()
}

// EventInfo — строка ленты событий.
type EventInfo struct {
	Kind      string    `json:"kind"`
	TrackID   string    `json:"track_id"`
	DeviceID  string    `json:"device_id"`
	ClientTS  int64     `json:"client_ts"`
	AppliedAt time.Time `json:"applied_at"`
	// Reason — причина удаления (см. PlayerView, 05.09.2026), пусто для
	// остальных видов событий и для удалений без выбранной причины.
	Reason string `json:"reason,omitempty"`
}

func (d *Pool) RecentEvents(ctx context.Context, limit int) ([]EventInfo, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	rows, err := d.p.Query(ctx, `
		SELECT kind, track_id, device_id, client_ts, applied_at, COALESCE(payload->>'reason', '')
		FROM sync_events ORDER BY applied_at DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]EventInfo, 0)
	for rows.Next() {
		var e EventInfo
		if err := rows.Scan(&e.Kind, &e.TrackID, &e.DeviceID, &e.ClientTS, &e.AppliedAt, &e.Reason); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
