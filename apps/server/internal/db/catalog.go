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
	Favorite    bool   `json:"favorite"`     // был в избранном старого плеера
	SizeBytes   int64  `json:"size_bytes"`   // размер файла (для бюджета «докачать ещё N ГБ»)
	BitrateKbps int    `json:"bitrate_kbps"` // характеристики файла — для строки в «Моей музыке»
	MimeType    string `json:"mime_type"`
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
	SELECT t.id, t.artist, t.title, t.album,
	       COALESCE(tf.duration_sec, t.duration_sec, 0),
	       t.release_kind, t.explicit, t.cover_url,
	       COALESCE(lm.kind = 'favorite', false) AS favorite,
	       COALESCE(tf.size_bytes, 0) AS size_bytes,
	       COALESCE(tf.bitrate_kbps, 0),
	       COALESCE(tf.mime_type, '')
	FROM tracks t
	LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
	LEFT JOIN track_files tf ON tf.track_id = t.id AND NOT tf.rejected
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
		if err := rows.Scan(&t.ID, &t.Artist, &t.Title, &t.Album, &t.DurationSec, &t.ReleaseKind, &t.Explicit, &t.CoverURL, &t.Favorite, &t.SizeBytes, &t.BitrateKbps, &t.MimeType); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// NextLibraryBatch — следующая порция для «докачать ещё N байт»: треки не из
// excludeIDs (то, что уже на телефоне), сначала избранное, затем остальное по
// порядку добавления, пока не наберём budgetBytes (или не кончится каталог).
// Возвращает выбранные треки и их суммарный размер.
func (d *Pool) NextLibraryBatch(ctx context.Context, excludeIDs []string, budgetBytes int64) ([]CatalogTrack, int64, error) {
	if d == nil || d.p == nil {
		return nil, 0, errNoDB
	}
	if excludeIDs == nil {
		excludeIDs = []string{}
	}
	// Пункт 4б: не отправляем на телефон концертные записи и обрезки
	// (файл короче 40 с — почти наверняка превью/битая закачка). Кавер/
	// ремикс/акустика тут НЕ трогаем — это ручной случай «не та версия».
	rows, err := d.p.Query(ctx, catalogSelect+`
		AND NOT (t.id = ANY($1))
		AND t.release_kind <> 'live'
		AND COALESCE(tf.duration_sec, t.duration_sec, 120) >= 40
		ORDER BY favorite DESC, t.created_at ASC
		LIMIT 5000`, excludeIDs)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	out := make([]CatalogTrack, 0)
	var total int64
	for rows.Next() {
		var t CatalogTrack
		if err := rows.Scan(&t.ID, &t.Artist, &t.Title, &t.Album, &t.DurationSec, &t.ReleaseKind, &t.Explicit, &t.CoverURL, &t.Favorite, &t.SizeBytes, &t.BitrateKbps, &t.MimeType); err != nil {
			return nil, 0, err
		}
		if len(out) > 0 && total >= budgetBytes {
			break
		}
		out = append(out, t)
		total += t.SizeBytes
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	return out, total, nil
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
//
// reordered = true только когда подбор по звуку реально состоялся (у seed есть
// отпечаток и хотя бы один кандидат по нему подошёл). Телефон по этому флагу
// решает, зажигать ли кнопку «Радио» и не писать ли «похожее не подобрать»
// вместо тихого no-op (Alex, 06.09.2026: радио сработало вхолостую, потому что
// у seed-песни не было отпечатка).
func (d *Pool) OrderBySimilarity(ctx context.Context, seedID string, candidateIDs []string) (ordered []string, reordered bool, err error) {
	if d == nil || d.p == nil {
		return nil, false, errNoDB
	}
	ordered = make([]string, 0, len(candidateIDs))
	seen := map[string]bool{seedID: true}

	type idArtist struct {
		id     string
		artist string
	}
	var byVec []idArtist

	if len(candidateIDs) > 0 {
		rows, qerr := d.p.Query(ctx, `
			WITH seed AS (SELECT feature_vector AS v FROM tracks WHERE id = $1)
			SELECT t.id, t.artist
			FROM tracks t, seed
			WHERE t.id = ANY($2)
			  AND t.id <> $1
			  AND t.feature_vector IS NOT NULL
			  AND seed.v IS NOT NULL
			ORDER BY t.feature_vector <=> seed.v`,
			seedID, candidateIDs)
		if qerr != nil {
			return nil, false, qerr
		}
		for rows.Next() {
			var ia idArtist
			if scanErr := rows.Scan(&ia.id, &ia.artist); scanErr != nil {
				rows.Close()
				return nil, false, scanErr
			}
			byVec = append(byVec, ia)
			seen[ia.id] = true
		}
		rows.Close()
		if rerr := rows.Err(); rerr != nil {
			return nil, false, rerr
		}
	}

	reordered = len(byVec) > 0

	// Раскидываем по исполнителю: подряд не больше двух одного и того же,
	// иначе радио вываливает целый альбом одним куском — Alex запустил радио
	// и получил 8 песен Кенни Роджерса подряд (06.09.2026). Жадно: если
	// набежало два подряд — берём ближайшего следующего с другим исполнителем,
	// а если других не осталось — что есть.
	var lastArtist string
	run := 0
	for len(byVec) > 0 {
		pick := 0
		if run >= 2 {
			for i, ia := range byVec {
				if !strings.EqualFold(ia.artist, lastArtist) {
					pick = i
					break
				}
			}
		}
		ia := byVec[pick]
		ordered = append(ordered, ia.id)
		byVec = append(byVec[:pick], byVec[pick+1:]...)
		if strings.EqualFold(ia.artist, lastArtist) {
			run++
		} else {
			lastArtist = ia.artist
			run = 1
		}
	}

	// хвост: кандидаты без отпечатка / seed без отпечатка — в исходном порядке
	for _, id := range candidateIDs {
		if !seen[id] {
			ordered = append(ordered, id)
			seen[id] = true
		}
	}
	return ordered, reordered, nil
}

// TrackForDeletion — normalized_key и канонический путь файла трека, для
// обработки события delete с телефона (см. api.handleDeleteEvents).
// ok=false — трек не наш (например, тестовый тон, у него нет строки в БД).
func (d *Pool) TrackForDeletion(ctx context.Context, trackID string) (normKey, filePath string, ok bool, err error) {
	if d == nil || d.p == nil {
		return "", "", false, errNoDB
	}
	err = d.p.QueryRow(ctx, `
		SELECT t.normalized_key, tf.file_path
		FROM tracks t JOIN track_files tf ON tf.track_id = t.id
		WHERE t.id = $1 AND NOT tf.rejected LIMIT 1`, trackID,
	).Scan(&normKey, &filePath)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", false, nil
	}
	if err != nil {
		return "", "", false, err
	}
	return normKey, filePath, true, nil
}

// SweepRow — трек каталога для повторной проверки по правилам качества
// (Sweep). FilePath — канонический.
type SweepRow struct {
	ID       string
	Artist   string
	Title    string
	NormKey  string
	FilePath string
}

// TracksForSweep — весь активный каталог (не blocked, файл не отклонён) для
// прогона через quality.Screen ещё раз — например, после того как список
// мусорных слов расширили и хочется почистить то, что уже успело попасть
// в каталог раньше.
func (d *Pool) TracksForSweep(ctx context.Context) ([]SweepRow, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	rows, err := d.p.Query(ctx, `
		SELECT t.id, t.artist, t.title, t.normalized_key, tf.file_path
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND NOT tf.rejected
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		WHERE lm.kind IS DISTINCT FROM 'blocked'`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]SweepRow, 0)
	for rows.Next() {
		var r SweepRow
		if err := rows.Scan(&r.ID, &r.Artist, &r.Title, &r.NormKey, &r.FilePath); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// TrackArtistTitle — артист/название трека по id. Нужно, когда после
// удаления с причиной "плохое качество"/"не та версия" сервер сам пробует
// найти замену получше (см. handleDeleteEvents, 05.09.2026) — для нового
// поиска через acquire нужны именно артист+название, не canonical-путь.
func (d *Pool) TrackArtistTitle(ctx context.Context, trackID string) (artist, title string, ok bool, err error) {
	if d == nil || d.p == nil {
		return "", "", false, errNoDB
	}
	err = d.p.QueryRow(ctx, `SELECT artist, title FROM tracks WHERE id = $1`, trackID).Scan(&artist, &title)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", false, nil
	}
	if err != nil {
		return "", "", false, err
	}
	return artist, title, true, nil
}

// DeleteTrack — стереть строку трека из каталога насовсем (track_files
// уходят каскадом). НЕ трогает файл на диске — это отдельно, через
// pathmap.MoveToTrash. Нужно для "переудаления" с причиной "плохое
// качество"/"не та версия" (05.09.2026): обычное удаление помечает
// blocked и трек больше никогда не всплывёт (это то, что нужно для
// "не нравится"/"надоела"), а тут наоборот — освобождаем normalized_key,
// чтобы acquire мог честно поискать замену, а не отдать эту же старую
// запись из каталога.
func (d *Pool) DeleteTrack(ctx context.Context, trackID string) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	_, err := d.p.Exec(ctx, `DELETE FROM tracks WHERE id = $1`, trackID)
	return err
}

// CoverCandidate — трек без обложки (ни своей в файле, ни найденной снаружи
// пока не проверяли) — кандидат на догон через Яндекс (см. adminBackfillCovers).
type CoverCandidate struct {
	ID       string
	Artist   string
	Title    string
	FilePath string
	// CoverURL — значение до этого догона ("" — всегда, раз попадает в
	// выборку; поле оставлено на будущее, если WHERE снова расширят).
	CoverURL string
}

// TracksMissingCoverURL — треки, у которых cover_url ещё пустой (никогда не
// смотрели вообще ни в одном источнике). Догон сам решает, чем пометить
// результат: "" — не смотрели, "embedded" — обложка своя, в файле (см.
// coverart.Embedded, в БД её не храним, ручка /v1/cover/{id} достаёт из
// файла заново), "none" — смотрели везде, не нашли, терминально: сюда же
// в выборку больше не попадает (иначе цикл не кончается — баг 05.09.2026,
// когда WHERE пускал и "none" на пересмотр и догон крутился по кругу
// бесконечно). Появится новый источник обложек — сознательно сбросить
// "none" обратно на "" вручную, разовым UPDATE. http(s)-ссылка — нашли
// внешнюю.
func (d *Pool) TracksMissingCoverURL(ctx context.Context, limit int) ([]CoverCandidate, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	rows, err := d.p.Query(ctx, `
		SELECT t.id, t.artist, t.title, tf.file_path, t.cover_url
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND NOT tf.rejected
		WHERE t.cover_url = ''
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]CoverCandidate, 0, limit)
	for rows.Next() {
		var c CoverCandidate
		if err := rows.Scan(&c.ID, &c.Artist, &c.Title, &c.FilePath, &c.CoverURL); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// SetCoverURL — записать результат проверки обложки трека (см.
// TracksMissingCoverURL про значения-метки).
func (d *Pool) SetCoverURL(ctx context.Context, id, url string) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	_, err := d.p.Exec(ctx, `UPDATE tracks SET cover_url = $1 WHERE id = $2`, url, id)
	return err
}

// TrackCoverURL — cover_url трека как есть (может быть меткой "embedded"/
// "none", а не настоящей ссылкой — вызывающий сам решает, что с ней делать).
func (d *Pool) TrackCoverURL(ctx context.Context, id string) (url string, found bool, err error) {
	if d == nil || d.p == nil {
		return "", false, errNoDB
	}
	err = d.p.QueryRow(ctx, `SELECT cover_url FROM tracks WHERE id = $1`, id).Scan(&url)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return url, url != "", nil
}

// TrackWaveform — Postgres-каталог рельеф громкости не хранит (это фича
// SQLite-сервера «одно приложение»). Всегда «не посчитан» → плеер рисует
// полоску как раньше.
func (d *Pool) TrackWaveform(ctx context.Context, id string) (bars []byte, found bool, err error) {
	return nil, false, nil
}

// DevicePlan / ClearDevicePlan — план ручной синхронизации живёт только в
// SQLite-сервере «одно приложение». В Postgres-варианте плана нет.
func (d *Pool) DevicePlan(ctx context.Context, deviceID string) (add []CatalogTrack, remove []string, at string, ok bool, err error) {
	return nil, nil, "", false, nil
}

func (d *Pool) ClearDevicePlan(ctx context.Context, deviceID string) error { return nil }

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
