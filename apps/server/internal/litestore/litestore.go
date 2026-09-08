// Package litestore — реализация интерфейсов api.Store / importer.Store /
// acquire.Store поверх лёгкой SQLite-базы (internal/localdb). Тот же
// проверенный HTTP-код телефона (internal/api) работает через неё вместо
// PostgreSQL — это и есть «полностью новый сервер» на fg.
//
// ctx в методах принимается для совпадения сигнатур с db.Pool и по-честному
// прокидывается в запросы; SQLite локальный, запросы субмиллисекундные.
package litestore

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
	"time"

	"soundflow/server/internal/db"
	"soundflow/server/internal/localdb"
)

// Store — SQLite-хранилище под телефонный/админский API.
type Store struct {
	d   *localdb.DB
	raw *sql.DB
}

// New оборачивает уже открытую localdb.DB.
func New(d *localdb.DB) *Store { return &Store{d: d, raw: d.SQL()} }

// Local — доступ к нижележащей localdb.DB (нужен коду, который уже написан
// под неё: сканер, пересчёт отпечатков).
func (s *Store) Local() *localdb.DB { return s.d }

// ---------- helpers ----------

func toDBCatalog(in []localdb.CatalogTrack) []db.CatalogTrack {
	out := make([]db.CatalogTrack, len(in))
	for i, t := range in {
		out[i] = db.CatalogTrack{
			ID: t.ID, Artist: t.Artist, Title: t.Title, Album: t.Album,
			DurationSec: t.DurationSec, ReleaseKind: t.ReleaseKind, Explicit: t.Explicit,
			CoverURL: t.CoverURL, Favorite: t.Favorite, SizeBytes: t.SizeBytes,
			BitrateKbps: t.BitrateKbps, MimeType: t.MimeType,
		}
	}
	return out
}

// parseTime — TEXT ISO-8601 из SQLite → *time.Time (nil для пустой строки).
// Возвращаем в локальной зоне: старый srv.exe (pgx + timestamptz) отдаёт время
// на проводе в локальной зоне сервера, телефон на это не завязан, но так
// ответы совпадают байт-в-байт при сверке.
func parseTime(s string) *time.Time {
	if s == "" {
		return nil
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02 15:04:05.999999-07:00", "2006-01-02 15:04:05"} {
		if t, err := time.Parse(layout, s); err == nil {
			t = t.Local()
			return &t
		}
	}
	return nil
}

func nullInt(v int) any {
	if v <= 0 {
		return nil
	}
	return v
}

// ---------- Ping / Migrate / Close (importer.Store) ----------

func (s *Store) Ping(ctx context.Context) error {
	if s == nil || s.raw == nil {
		return errors.New("нет базы")
	}
	return s.raw.PingContext(ctx)
}

// Migrate — схема уже накатана localdb.Open. Ничего не делаем.
func (s *Store) Migrate(ctx context.Context) error { return nil }

func (s *Store) Close() {
	if s != nil && s.d != nil {
		_ = s.d.Close()
	}
}

// ---------- каталог: чтение ----------

func (s *Store) CatalogList(ctx context.Context, limit int) ([]db.CatalogTrack, error) {
	list, err := s.d.CatalogList(limit)
	return toDBCatalog(list), err
}

func (s *Store) CatalogSearch(ctx context.Context, q string, limit int) ([]db.CatalogTrack, error) {
	list, err := s.d.CatalogSearch(q, limit)
	return toDBCatalog(list), err
}

func (s *Store) NextLibraryBatch(ctx context.Context, excludeIDs []string, budgetBytes int64) ([]db.CatalogTrack, int64, error) {
	list, total, err := s.d.NextLibraryBatch(excludeIDs, budgetBytes)
	return toDBCatalog(list), total, err
}

func (s *Store) OrderBySimilarity(ctx context.Context, seedID string, candidateIDs []string) ([]string, bool, error) {
	// «Умное радио» (TASTE-PLAN §7): OrderRadio учитывает вкус поверх
	// близости звука; нет сигналов вкуса — он сам падает на чистый косинус.
	return s.d.OrderRadio(seedID, candidateIDs)
}

func (s *Store) TrackFilePath(ctx context.Context, trackID string) (string, bool, error) {
	return s.d.TrackFilePath(trackID)
}

func (s *Store) TrackCoverURL(ctx context.Context, id string) (string, bool, error) {
	return s.d.TrackCoverURL(id)
}

func (s *Store) TrackWaveform(ctx context.Context, id string) ([]byte, bool, error) {
	return s.d.Waveform(id)
}

func (s *Store) SetWaveform(ctx context.Context, id string, bars []byte) error {
	return s.d.SetWaveform(id, bars)
}

func (s *Store) TrackIDsWithoutFeatures(ctx context.Context, limit int) ([]string, error) {
	return s.d.TrackIDsWithoutFeatures(limit)
}

func (s *Store) TrackByKey(ctx context.Context, normKey string) (*db.CatalogTrack, error) {
	var t db.CatalogTrack
	err := s.raw.QueryRowContext(ctx, `
		SELECT id, artist, title, album, COALESCE(duration_sec,0), release_kind, explicit, cover_url
		FROM tracks WHERE normalized_key = ? LIMIT 1`, normKey,
	).Scan(&t.ID, &t.Artist, &t.Title, &t.Album, &t.DurationSec, &t.ReleaseKind, &t.Explicit, &t.CoverURL)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func (s *Store) TrackArtistTitle(ctx context.Context, trackID string) (artist, title string, ok bool, err error) {
	err = s.raw.QueryRowContext(ctx, `SELECT artist, title FROM tracks WHERE id = ?`, trackID).Scan(&artist, &title)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", false, nil
	}
	if err != nil {
		return "", "", false, err
	}
	return artist, title, true, nil
}

func (s *Store) TrackForDeletion(ctx context.Context, trackID string) (normKey, filePath string, ok bool, err error) {
	err = s.raw.QueryRowContext(ctx, `
		SELECT t.normalized_key, tf.file_path
		FROM tracks t JOIN track_files tf ON tf.track_id = t.id
		WHERE t.id = ? AND tf.rejected = 0 LIMIT 1`, trackID,
	).Scan(&normKey, &filePath)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", false, nil
	}
	if err != nil {
		return "", "", false, err
	}
	return normKey, filePath, true, nil
}

func (s *Store) TracksForSweep(ctx context.Context) ([]db.SweepRow, error) {
	rows, err := s.raw.QueryContext(ctx, `
		SELECT t.id, t.artist, t.title, t.normalized_key, tf.file_path
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		WHERE lm.kind IS NOT 'blocked'`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]db.SweepRow, 0)
	for rows.Next() {
		var r db.SweepRow
		if err := rows.Scan(&r.ID, &r.Artist, &r.Title, &r.NormKey, &r.FilePath); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) TracksMissingCoverURL(ctx context.Context, limit int) ([]db.CoverCandidate, error) {
	rows, err := s.raw.QueryContext(ctx, `
		SELECT t.id, t.artist, t.title, tf.file_path, t.cover_url
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		WHERE t.cover_url = ''
		LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]db.CoverCandidate, 0, limit)
	for rows.Next() {
		var c db.CoverCandidate
		if err := rows.Scan(&c.ID, &c.Artist, &c.Title, &c.FilePath, &c.CoverURL); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ---------- каталог: запись ----------

func (s *Store) InsertTrackWithFile(ctx context.Context, t db.NewTrack, f db.NewTrackFile) error {
	return s.d.InsertTrackWithFile(
		localdb.NewTrack{
			ID: t.ID, Artist: t.Artist, Title: t.Title, Album: t.Album,
			DurationSec: t.DurationSec, ReleaseKind: t.ReleaseKind,
			NormalizedKey: t.NormalizedKey, CoverURL: t.CoverURL,
		},
		localdb.NewTrackFile{
			ID: f.ID, NormalizedKey: f.NormalizedKey, FilePath: f.FilePath,
			MimeType: f.MimeType, BitrateKbps: f.BitrateKbps, SizeBytes: f.SizeBytes,
			DurationSec: f.DurationSec, Source: f.Source, QualityTier: f.QualityTier,
		},
	)
}

func (s *Store) SetFeatureVector(ctx context.Context, trackID string, v []float32) error {
	return s.d.SetFeatureVector(trackID, v)
}

func (s *Store) DeleteTrack(ctx context.Context, trackID string) error {
	_, err := s.raw.ExecContext(ctx, `DELETE FROM tracks WHERE id = ?`, trackID)
	return err
}

func (s *Store) DeleteTrackByKey(ctx context.Context, normKey string) error {
	_, err := s.raw.ExecContext(ctx, `DELETE FROM tracks WHERE normalized_key = ?`, normKey)
	return err
}

func (s *Store) SetCoverURL(ctx context.Context, id, url string) error {
	_, err := s.raw.ExecContext(ctx, `UPDATE tracks SET cover_url = ? WHERE id = ?`, url, id)
	return err
}

func (s *Store) RecordRejected(ctx context.Context, normKey, sourceURL, provider, artist, title, reason string) error {
	var su any
	if sourceURL != "" {
		su = sourceURL
	}
	_, err := s.raw.ExecContext(ctx, `
		INSERT INTO rejected_track_files (normalized_key, source_url, provider, artist, title, reason)
		VALUES (?,?,?,?,?,?)
		ON CONFLICT (normalized_key, source_url) DO NOTHING`,
		normKey, su, provider, artist, title, reason)
	return err
}

// ---------- legacy_marks (Корзина / чёрный список) ----------

func (s *Store) LegacyMarkKind(ctx context.Context, normKey string) (string, error) {
	var kind string
	err := s.raw.QueryRowContext(ctx, `SELECT kind FROM legacy_marks WHERE normalized_key = ?`, normKey).Scan(&kind)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return kind, err
}

func (s *Store) DeleteLegacyMark(ctx context.Context, normKey string) error {
	_, err := s.raw.ExecContext(ctx, `DELETE FROM legacy_marks WHERE normalized_key = ?`, normKey)
	return err
}

func (s *Store) UpsertLegacyMark(ctx context.Context, m db.LegacyMark) error {
	var at any
	if !m.At.IsZero() {
		at = m.At.UTC().Format(time.RFC3339Nano)
	}
	_, err := s.raw.ExecContext(ctx, `
		INSERT INTO legacy_marks (normalized_key, kind, artist, title, marked_at)
		VALUES (?,?,?,?,?)
		ON CONFLICT (normalized_key) DO UPDATE SET
			kind = excluded.kind, artist = excluded.artist,
			title = excluded.title, marked_at = excluded.marked_at`,
		m.Key, m.Kind, m.Artist, m.Title, at)
	return err
}

func (s *Store) LegacyMarksInsert(ctx context.Context, marks map[string]db.LegacyMark) (int, error) {
	if len(marks) == 0 {
		return 0, nil
	}
	tx, err := s.raw.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback() //nolint:errcheck
	n := 0
	for _, m := range marks {
		var at any
		if !m.At.IsZero() {
			at = m.At.UTC().Format(time.RFC3339Nano)
		}
		res, err := tx.ExecContext(ctx, `
			INSERT INTO legacy_marks (normalized_key, kind, artist, title, marked_at)
			VALUES (?,?,?,?,?)
			ON CONFLICT (normalized_key) DO NOTHING`,
			m.Key, m.Kind, m.Artist, m.Title, at)
		if err != nil {
			return 0, err
		}
		if k, _ := res.RowsAffected(); k > 0 {
			n++
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return n, nil
}

func (s *Store) TrashedTracks(ctx context.Context) ([]db.TrashedRow, error) {
	rows, err := s.raw.QueryContext(ctx, `
		SELECT t.id, t.artist, t.title, t.normalized_key, COALESCE(lm.marked_at,'')
		FROM legacy_marks lm
		JOIN tracks t ON t.normalized_key = lm.normalized_key
		WHERE lm.kind = 'blocked'
		ORDER BY (lm.marked_at IS NULL OR lm.marked_at = ''), lm.marked_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]db.TrashedRow, 0)
	for rows.Next() {
		var r db.TrashedRow
		var at string
		if err := rows.Scan(&r.TrackID, &r.Artist, &r.Title, &r.NormKey, &at); err != nil {
			return nil, err
		}
		r.MarkedAt = parseTime(at)
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) ListBlocked(ctx context.Context, limit int) ([]db.BlockedRow, error) {
	q := `
		SELECT lm.normalized_key,
		       COALESCE(NULLIF(t.artist,''), lm.artist) AS artist,
		       COALESCE(NULLIF(t.title,''),  lm.title)  AS title,
		       (t.id IS NOT NULL) AS in_catalog,
		       COALESCE(lm.marked_at,'')
		FROM legacy_marks lm
		LEFT JOIN tracks t ON t.normalized_key = lm.normalized_key
		WHERE lm.kind = 'blocked'
		ORDER BY (lm.marked_at IS NULL OR lm.marked_at = ''), lm.marked_at DESC, lm.normalized_key`
	if limit > 0 {
		q += "\n\t\tLIMIT " + strconv.Itoa(limit)
	}
	rows, err := s.raw.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]db.BlockedRow, 0)
	for rows.Next() {
		var r db.BlockedRow
		var at string
		var inCat int
		if err := rows.Scan(&r.Key, &r.Artist, &r.Title, &inCat, &at); err != nil {
			return nil, err
		}
		r.InCat = inCat != 0
		r.At = parseTime(at)
		out = append(out, r)
	}
	return out, rows.Err()
}

// ---------- синхронизация ----------

func (s *Store) SaveSync(ctx context.Context, dev db.Device, events []db.SyncEvent) ([]string, error) {
	le := make([]localdb.SyncEvent, len(events))
	for i, e := range events {
		le[i] = localdb.SyncEvent{UUID: e.UUID, Kind: e.Kind, TrackID: e.TrackID, Payload: e.Payload, ClientTS: e.ClientTS}
	}
	return s.d.SaveSync(
		localdb.Device{
			ID: dev.ID, Name: dev.Name, AppVersion: dev.AppVersion,
			MusicBytes: dev.MusicBytes, Transport: dev.Transport,
		},
		le,
	)
}

func (s *Store) SyncReport(ctx context.Context, deviceID string) (*time.Time, int64, error) {
	return s.d.SyncReport(deviceID)
}

// DevicePlan — план ручной синхронизации: id из sync_plans + полные карточки
// треков к закачке (localdb.TracksByIDs). Плана нет → ok=false.
func (s *Store) DevicePlan(ctx context.Context, deviceID string) ([]db.CatalogTrack, []string, string, bool, error) {
	addIDs, remove, at, ok, err := s.d.Plan(deviceID)
	if err != nil || !ok {
		return nil, nil, "", ok, err
	}
	var add []db.CatalogTrack
	if len(addIDs) > 0 {
		list, e := s.d.TracksByIDs(addIDs)
		if e != nil {
			return nil, nil, "", false, e
		}
		add = toDBCatalog(list)
	}
	return add, remove, at, true, nil
}

func (s *Store) ClearDevicePlan(ctx context.Context, deviceID string) error {
	return s.d.ClearPlan(deviceID)
}

// ---------- журнал сервера / отчёты ----------

func (s *Store) AddServerLog(ctx context.Context, kind, artist, title, detail string, bytes int64) error {
	return s.d.AddServerLog(kind, artist, title, detail, bytes)
}

func (s *Store) RecentServerLog(ctx context.Context, limit int) ([]db.ServerLogRow, error) {
	rows, err := s.d.RecentServerLog(limit)
	if err != nil {
		return nil, err
	}
	out := make([]db.ServerLogRow, len(rows))
	for i, r := range rows {
		out[i] = db.ServerLogRow{
			At: r.At.Local(), Kind: r.Kind, Artist: r.Artist, Title: r.Title,
			Detail: r.Detail, Bytes: r.Bytes,
		}
	}
	return out, nil
}

func (s *Store) RecentEvents(ctx context.Context, limit int) ([]db.EventInfo, error) {
	rows, err := s.raw.QueryContext(ctx, `
		SELECT kind, track_id, device_id, client_ts, COALESCE(applied_at,''),
		       COALESCE(json_extract(payload,'$.reason'),'')
		FROM sync_events ORDER BY applied_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]db.EventInfo, 0)
	for rows.Next() {
		var e db.EventInfo
		var applied string
		if err := rows.Scan(&e.Kind, &e.TrackID, &e.DeviceID, &e.ClientTS, &applied, &e.Reason); err != nil {
			return nil, err
		}
		if t := parseTime(applied); t != nil {
			e.AppliedAt = *t
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (s *Store) ListDevices(ctx context.Context) ([]db.DeviceInfo, error) {
	rows, err := s.raw.QueryContext(ctx, `
		SELECT d.id, d.name, d.app_version, d.music_bytes,
		       COALESCE(d.last_sync_at,''), COALESCE(d.created_at,''),
		       COALESCE(d.transport,''),
		       (SELECT count(*) FROM sync_events e WHERE e.device_id = d.id)
		FROM devices d
		ORDER BY (d.last_sync_at IS NULL OR d.last_sync_at = ''), d.last_sync_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]db.DeviceInfo, 0)
	for rows.Next() {
		var di db.DeviceInfo
		var last, created string
		if err := rows.Scan(&di.ID, &di.Name, &di.AppVersion, &di.MusicBytes, &last, &created, &di.Transport, &di.Events); err != nil {
			return nil, err
		}
		di.LastSyncAt = parseTime(last)
		if t := parseTime(created); t != nil {
			di.CreatedAt = *t
		}
		out = append(out, di)
	}
	return out, rows.Err()
}

func (s *Store) AdminStatus(ctx context.Context) (db.AdminStatus, error) {
	var st db.AdminStatus
	err := s.raw.QueryRowContext(ctx, `
		SELECT (SELECT count(*) FROM tracks),
		       (SELECT count(*) FROM track_files),
		       (SELECT count(*) FROM sync_events),
		       (SELECT count(*) FROM devices),
		       (SELECT count(*) FROM legacy_marks WHERE kind = 'favorite'),
		       (SELECT count(*) FROM legacy_marks WHERE kind = 'blocked'),
		       (SELECT COALESCE(sum(size_bytes), 0) FROM track_files),
		       (SELECT count(*) FROM tracks t
		          LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		          LEFT JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		         WHERE lm.kind IS NOT 'blocked'
		           AND (t.release_kind = 'live'
		                OR COALESCE(tf.duration_sec, t.duration_sec, 120) < 40))`,
	).Scan(&st.Tracks, &st.TrackFiles, &st.EventsTotal, &st.Devices,
		&st.LegacyFavs, &st.LegacyBlocked, &st.MusicBytes, &st.HiddenByQ)
	if err != nil {
		return st, err
	}
	st.EventsByKind = map[string]int64{}
	rows, err := s.raw.QueryContext(ctx, `SELECT kind, count(*) FROM sync_events GROUP BY kind ORDER BY kind`)
	if err != nil {
		return st, err
	}
	defer rows.Close()
	for rows.Next() {
		var k string
		var n int64
		if err := rows.Scan(&k, &n); err != nil {
			return st, err
		}
		st.EventsByKind[k] = n
	}
	st.Migrations = []string{} // у SQLite-базы миграций как таковых нет
	return st, rows.Err()
}

func (s *Store) ServerReportSince(ctx context.Context, days int) (db.ServerReport, error) {
	rep := db.ServerReport{Days: days}
	if days <= 0 {
		days = 30
	}
	rep.Days = days
	rep.Since = time.Now().Add(-time.Duration(days) * 24 * time.Hour)
	rows, err := s.raw.QueryContext(ctx, `
		SELECT kind, count(*), COALESCE(sum(bytes), 0)
		FROM server_log WHERE at >= ? GROUP BY kind`, rep.Since.UTC().Format(time.RFC3339Nano))
	if err != nil {
		return rep, err
	}
	defer rows.Close()
	for rows.Next() {
		var k string
		var n, b int64
		if err := rows.Scan(&k, &n, &b); err != nil {
			return rep, err
		}
		switch k {
		case db.LogAdded:
			rep.Added = n
		case db.LogRemoved:
			rep.Removed = n
			rep.FreedBytes += b
		case db.LogNotFound:
			rep.NotFound = n
		case db.LogReplaced:
			rep.Replaced = n
		case db.LogError:
			rep.Errors = n
		}
	}
	return rep, rows.Err()
}

var _ = nullInt // на случай, если понадобится для будущих вставок
