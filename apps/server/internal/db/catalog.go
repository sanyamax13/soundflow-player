package db

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// CatalogTrack — трек в каталоге (для списка и поиска на телефоне).
type CatalogTrack struct {
	ID          string `json:"id"`
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	DurationSec int    `json:"duration_sec"`
	ReleaseKind string `json:"release_kind"`
	Explicit    bool   `json:"explicit"`
	CoverURL    string `json:"cover_url"`
}

// NewTrack + NewTrackFile — что вставляем после успешного скачивания.
type NewTrack struct {
	ID            string
	Artist        string
	Title         string
	Album         string
	DurationSec   int
	ReleaseKind   string
	Explicit      bool
	IsAltVersion  bool
	NormalizedKey string
	CoverURL      string
}

type NewTrackFile struct {
	ID            string
	NormalizedKey string
	FilePath      string // канонический
	MimeType      string
	BitrateKbps   int
	SizeBytes     int64
	DurationSec   int
	Source        string
	QualityTier   string
}

// TrackByKey — есть ли уже трек с таким normalized_key.
func (d *Pool) TrackByKey(ctx context.Context, normKey string) (*CatalogTrack, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	var t CatalogTrack
	err := d.p.QueryRow(ctx, `
		SELECT id, artist, title, album, COALESCE(duration_sec,0), release_kind, explicit, cover_url
		FROM tracks WHERE normalized_key = $1 LIMIT 1`, normKey,
	).Scan(&t.ID, &t.Artist, &t.Title, &t.Album, &t.DurationSec, &t.ReleaseKind, &t.Explicit, &t.CoverURL)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// InsertTrackWithFile — трек + файл одной транзакцией.
func (d *Pool) InsertTrackWithFile(ctx context.Context, t NewTrack, f NewTrackFile) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	tx, err := d.p.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	if _, err := tx.Exec(ctx, `
		INSERT INTO tracks
			(id, artist, title, album, duration_sec, release_kind, explicit, is_alt_version, normalized_key, cover_url)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
		t.ID, t.Artist, t.Title, t.Album, nullInt(t.DurationSec), t.ReleaseKind, t.Explicit, t.IsAltVersion, t.NormalizedKey, t.CoverURL,
	); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO track_files
			(id, track_id, normalized_key, file_path, mime_type, bitrate_kbps, size_bytes, duration_sec, source, quality_tier)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
		ON CONFLICT (normalized_key) DO NOTHING`,
		f.ID, t.ID, f.NormalizedKey, f.FilePath, f.MimeType, nullInt(f.BitrateKbps), f.SizeBytes, nullInt(f.DurationSec), f.Source, f.QualityTier,
	); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// RecordRejected — отпечаток отклонённого источника (не возвращаться к нему).
func (d *Pool) RecordRejected(ctx context.Context, normKey, sourceURL, provider, artist, title, reason string) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	_, err := d.p.Exec(ctx, `
		INSERT INTO rejected_track_files (normalized_key, source_url, provider, artist, title, reason)
		VALUES ($1,$2,$3,$4,$5,$6)
		ON CONFLICT (normalized_key, source_url) DO NOTHING`,
		normKey, nullStr(sourceURL), provider, artist, title, reason)
	return err
}

// CatalogList — весь каталог (для /v1/tracks).
func (d *Pool) CatalogList(ctx context.Context, limit int) ([]CatalogTrack, error) {
	return d.catalogQuery(ctx, `
		SELECT id, artist, title, album, COALESCE(duration_sec,0), release_kind, explicit, cover_url
		FROM tracks ORDER BY created_at DESC LIMIT $1`, limit)
}

// CatalogSearch — поиск по артисту/названию.
func (d *Pool) CatalogSearch(ctx context.Context, q string, limit int) ([]CatalogTrack, error) {
	return d.catalogQuery(ctx, `
		SELECT id, artist, title, album, COALESCE(duration_sec,0), release_kind, explicit, cover_url
		FROM tracks
		WHERE artist ILIKE '%' || $2 || '%' OR title ILIKE '%' || $2 || '%'
		ORDER BY created_at DESC LIMIT $1`, limit, q)
}

func (d *Pool) catalogQuery(ctx context.Context, sql string, args ...any) ([]CatalogTrack, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	rows, err := d.p.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]CatalogTrack, 0)
	for rows.Next() {
		var t CatalogTrack
		if err := rows.Scan(&t.ID, &t.Artist, &t.Title, &t.Album, &t.DurationSec, &t.ReleaseKind, &t.Explicit, &t.CoverURL); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// DeleteTrackByKey — убрать трек из каталога по normalized_key (track_files
// снимутся каскадом). Пригодится для «удалить из каталога» и в тестах.
func (d *Pool) DeleteTrackByKey(ctx context.Context, normKey string) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	_, err := d.p.Exec(ctx, `DELETE FROM tracks WHERE normalized_key = $1`, normKey)
	return err
}

// TrackFilePath — канонический путь файла трека (для отдачи /v1/music/{id}/file).
func (d *Pool) TrackFilePath(ctx context.Context, trackID string) (string, bool, error) {
	if d == nil || d.p == nil {
		return "", false, errNoDB
	}
	var p string
	err := d.p.QueryRow(ctx,
		`SELECT file_path FROM track_files WHERE track_id = $1 AND NOT rejected LIMIT 1`, trackID,
	).Scan(&p)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return p, true, nil
}

func nullInt(v int) any {
	if v <= 0 {
		return nil
	}
	return v
}

func nullStr(v string) any {
	if v == "" {
		return nil
	}
	return v
}
