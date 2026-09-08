package localdb

import (
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// --- каталог: вставка/обновление (нужно сканеру и пересчёту отпечатков) ---

// NewTrack + NewTrackFile — что кладём после того, как нашли файл на диске.
type NewTrack struct {
	ID, Artist, Title, Album string
	Year                     int
	DurationSec              int
	ReleaseKind              string
	NormalizedKey            string
	CoverURL                 string
	GenreTags                []string
}

type NewTrackFile struct {
	ID, NormalizedKey, FilePath, MimeType string
	BitrateKbps                           int
	SizeBytes                             int64
	DurationSec                           int
	Source, QualityTier                   string
}

// InsertTrackWithFile — трек + файл одной транзакцией. search_text считаем тут.
func (d *DB) InsertTrackWithFile(t NewTrack, f NewTrackFile) error {
	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	tags := "[]"
	if len(t.GenreTags) > 0 {
		b, _ := json.Marshal(t.GenreTags)
		tags = string(b)
	}
	rk := t.ReleaseKind
	if rk == "" {
		rk = "studio"
	}
	search := strings.ToLower(t.Artist + " " + t.Title + " " + t.Album)
	if _, err := tx.Exec(`
		INSERT INTO tracks (id,artist,title,album,year,duration_sec,genre_tags,
		                    release_kind,normalized_key,cover_url,created_at,search_text)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(id) DO NOTHING`,
		t.ID, t.Artist, t.Title, t.Album, nullInt(t.Year), nullInt(t.DurationSec),
		tags, rk, t.NormalizedKey, t.CoverURL, time.Now().UTC().Format(time.RFC3339), search,
	); err != nil {
		return err
	}
	if _, err := tx.Exec(`
		INSERT INTO track_files (id,track_id,normalized_key,file_path,mime_type,
		                         bitrate_kbps,size_bytes,duration_sec,source,quality_tier,downloaded_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(normalized_key) DO NOTHING`,
		f.ID, t.ID, f.NormalizedKey, f.FilePath, f.MimeType, nullInt(f.BitrateKbps),
		f.SizeBytes, nullInt(f.DurationSec), f.Source, def(f.QualityTier, "unknown"),
		time.Now().UTC().Format(time.RFC3339),
	); err != nil {
		return err
	}
	return tx.Commit()
}

// SetFeatureVector — записать/обновить звуковой отпечаток трека.
func (d *DB) SetFeatureVector(trackID string, v []float32) error {
	_, err := d.sql.Exec(`UPDATE tracks SET feature_vector = ? WHERE id = ?`, vecToBlob(v), trackID)
	return err
}

// SetWaveform — «рельеф громкости» трека (N байт 0..255) для полоски плеера.
func (d *DB) SetWaveform(trackID string, b []byte) error {
	_, err := d.sql.Exec(`UPDATE tracks SET waveform = ? WHERE id = ?`, b, trackID)
	return err
}

// Waveform — рельеф громкости трека. found=false — ещё не посчитан.
func (d *DB) Waveform(trackID string) (b []byte, found bool, err error) {
	err = d.sql.QueryRow(`SELECT waveform FROM tracks WHERE id = ?`, trackID).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return b, len(b) > 0, nil
}

// FeatureVector — отпечаток трека ([]float32) и есть ли он.
func (d *DB) FeatureVector(trackID string) ([]float32, bool, error) {
	v, err := d.featureVector(trackID)
	return v, len(v) > 0, err
}

// TrackIDsNeedingAnalysis — треки без отпечатка ИЛИ без рельефа громкости
// (для «Переиндексировать»: считает недостающее из двух).
func (d *DB) TrackIDsNeedingAnalysis(limit int) ([]string, error) {
	q := `SELECT id FROM tracks WHERE feature_vector IS NULL OR waveform IS NULL ORDER BY created_at`
	if limit > 0 {
		q += " LIMIT ?"
	}
	var rows *sql.Rows
	var err error
	if limit > 0 {
		rows, err = d.sql.Query(q, limit)
	} else {
		rows, err = d.sql.Query(q)
	}
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
	}
	return out, rows.Err()
}

// TrackIDsWithoutFeatures — id треков без отпечатка (для «Переиндексировать»).
func (d *DB) TrackIDsWithoutFeatures(limit int) ([]string, error) {
	q := `SELECT id FROM tracks WHERE feature_vector IS NULL ORDER BY created_at`
	if limit > 0 {
		q += " LIMIT ?"
	}
	var rows *sql.Rows
	var err error
	if limit > 0 {
		rows, err = d.sql.Query(q, limit)
	} else {
		rows, err = d.sql.Query(q)
	}
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
	}
	return out, rows.Err()
}

// TrackExistsByKey — уже есть трек/файл с таким normalized_key (сканер).
func (d *DB) TrackExistsByKey(normKey string) (bool, error) {
	var one int
	err := d.sql.QueryRow(`SELECT 1 FROM track_files WHERE normalized_key = ? LIMIT 1`, normKey).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// --- журнал сервера ---

// AddServerLog — строка в ленту «что сервер делал».
func (d *DB) AddServerLog(kind, artist, title, detail string, bytes int64) error {
	_, err := d.sql.Exec(`
		INSERT INTO server_log (at,kind,artist,title,detail,bytes) VALUES (?,?,?,?,?,?)`,
		time.Now().UTC().Format(time.RFC3339Nano), kind, artist, title, detail, bytes)
	return err
}

// ServerLogRow — строка ленты.
type ServerLogRow struct {
	At     time.Time `json:"at"`
	Kind   string    `json:"kind"`
	Artist string    `json:"artist"`
	Title  string    `json:"title"`
	Detail string    `json:"detail"`
	Bytes  int64     `json:"bytes"`
}

func (d *DB) RecentServerLog(limit int) ([]ServerLogRow, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := d.sql.Query(
		`SELECT at,kind,artist,title,detail,bytes FROM server_log ORDER BY at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ServerLogRow, 0, limit)
	for rows.Next() {
		var r ServerLogRow
		var at string
		if err := rows.Scan(&at, &r.Kind, &r.Artist, &r.Title, &r.Detail, &r.Bytes); err != nil {
			return nil, err
		}
		r.At, _ = time.Parse(time.RFC3339Nano, at)
		out = append(out, r)
	}
	return out, rows.Err()
}

// --- устройства ---

// DeviceInfo — телефон в списке «Устройства».
type DeviceInfo struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	AppVersion string     `json:"app_version"`
	MusicBytes int64      `json:"music_bytes"`
	LastSyncAt *time.Time `json:"last_sync_at"`
	Events     int64      `json:"events"`
	Transport  string     `json:"transport"`
}

func (d *DB) ListDevices() ([]DeviceInfo, error) {
	rows, err := d.sql.Query(`
		SELECT d.id, d.name, d.app_version, d.music_bytes, d.last_sync_at,
		       (SELECT count(*) FROM sync_events e WHERE e.device_id = d.id),
		       COALESCE(d.transport, '')
		FROM devices d ORDER BY d.last_sync_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]DeviceInfo, 0)
	for rows.Next() {
		var x DeviceInfo
		var last sql.NullString
		if err := rows.Scan(&x.ID, &x.Name, &x.AppVersion, &x.MusicBytes, &last, &x.Events, &x.Transport); err != nil {
			return nil, err
		}
		if last.Valid {
			if tt, e := time.Parse(time.RFC3339Nano, last.String); e == nil {
				x.LastSyncAt = &tt
			} else if tt, e := time.Parse(time.RFC3339, last.String); e == nil {
				x.LastSyncAt = &tt
			}
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

// Counts — сводка для шапки окна.
type Counts struct {
	Tracks      int64 `json:"tracks"`
	WithVector  int64 `json:"with_vector"`
	TrackFiles  int64 `json:"track_files"`
	AlbumsGuess int64 `json:"albums_guess"`
}

func (d *DB) Counts() (Counts, error) {
	var c Counts
	err := d.sql.QueryRow(`
		SELECT (SELECT count(*) FROM tracks),
		       (SELECT count(*) FROM tracks WHERE feature_vector IS NOT NULL),
		       (SELECT count(*) FROM track_files WHERE rejected = 0),
		       (SELECT count(DISTINCT album) FROM tracks WHERE album <> '')`).
		Scan(&c.Tracks, &c.WithVector, &c.TrackFiles, &c.AlbumsGuess)
	return c, err
}

func nullInt(v int) any {
	if v <= 0 {
		return nil
	}
	return v
}

func def(v, d string) string {
	if v == "" {
		return d
	}
	return v
}
