package db

import (
	"context"
	"errors"
	"strconv"
	"strings"

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
	Favorite    bool   `json:"favorite"` // был в избранном старого плеера
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

// catalogSelect — общая выборка: помечает favorite из legacy_marks и прячет
// треки, отмеченные там как blocked (в старом плеере удалены/скрыты).
const catalogSelect = `
	SELECT t.id, t.artist, t.title, t.album, COALESCE(t.duration_sec,0),
	       t.release_kind, t.explicit, t.cover_url,
	       COALESCE(lm.kind = 'favorite', false) AS favorite
	FROM tracks t
	LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
	WHERE lm.kind IS DISTINCT FROM 'blocked'`

// CatalogList — весь каталог (для /v1/tracks).
func (d *Pool) CatalogList(ctx context.Context, limit int) ([]CatalogTrack, error) {
	return d.catalogQuery(ctx, catalogSelect+`
		ORDER BY t.created_at DESC LIMIT $1`, limit)
}

// CatalogSearch — поиск по артисту/названию.
func (d *Pool) CatalogSearch(ctx context.Context, q string, limit int) ([]CatalogTrack, error) {
	return d.catalogQuery(ctx, catalogSelect+`
		AND (t.artist ILIKE '%' || $2 || '%' OR t.title ILIKE '%' || $2 || '%')
		ORDER BY t.created_at DESC LIMIT $1`, limit, q)
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
		if err := rows.Scan(&t.ID, &t.Artist, &t.Title, &t.Album, &t.DurationSec, &t.ReleaseKind, &t.Explicit, &t.CoverURL, &t.Favorite); err != nil {
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

// --- умное радио (этап 9): звуковой отпечаток и подбор похожих ---

// vecLiteral — []float32 → pgvector-литерал "[0.1,0.2,...]".
func vecLiteral(v []float32) string {
	var b strings.Builder
	b.Grow(len(v) * 12)
	b.WriteByte('[')
	for i, f := range v {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(strconv.FormatFloat(float64(f), 'g', -1, 32))
	}
	b.WriteByte(']')
	return b.String()
}

// SetFeatureVector — записать «звуковой отпечаток» трека (2048-мерный).
func (d *Pool) SetFeatureVector(ctx context.Context, trackID string, v []float32) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	_, err := d.p.Exec(ctx,
		`UPDATE tracks SET feature_vector = $2::vector WHERE id = $1`,
		trackID, vecLiteral(v))
	return err
}

// TrackIDsWithoutFeatures — id треков без отпечатка (для догона /admin/reanalyze).
func (d *Pool) TrackIDsWithoutFeatures(ctx context.Context, limit int) ([]string, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	rows, err := d.p.Query(ctx,
		`SELECT id FROM tracks WHERE feature_vector IS NULL ORDER BY created_at LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]string, 0)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// OrderBySimilarity — упорядочить candidateIDs по близости звучания к seedID
// (косинус, pgvector `<=>`). seedID из результата исключается. Треки без
// отпечатка (и весь список, если у seed нет отпечатка) идут в хвост в исходном
// порядке — чтобы очередь Потока всё равно доиграла.
func (d *Pool) OrderBySimilarity(ctx context.Context, seedID string, candidateIDs []string) ([]string, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	ordered := make([]string, 0, len(candidateIDs))
	seen := map[string]bool{seedID: true}

	if len(candidateIDs) > 0 {
		rows, err := d.p.Query(ctx, `
			WITH seed AS (SELECT feature_vector AS v FROM tracks WHERE id = $1)
			SELECT t.id
			FROM tracks t, seed
			WHERE t.id = ANY($2)
			  AND t.id <> $1
			  AND t.feature_vector IS NOT NULL
			  AND seed.v IS NOT NULL
			ORDER BY t.feature_vector <=> seed.v`,
			seedID, candidateIDs)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, err
			}
			ordered = append(ordered, id)
			seen[id] = true
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}

	// хвост: кандидаты без отпечатка / seed без отпечатка — в исходном порядке
	for _, id := range candidateIDs {
		if !seen[id] {
			ordered = append(ordered, id)
			seen[id] = true
		}
	}
	return ordered, nil
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
