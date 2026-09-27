// Package localdb — лёгкая (SQLite) копия каталога для «SoundFlow в одном exe».
// Пока теневая: наполняется одноразовым импортёром из Postgres
// (cmd/soundflow-import), рабочий сервер продолжает читать Postgres. Задача
// пакета — доказать, что «поиск / похожие / докачать» на SQLite дают тот же
// результат (см. cmd/soundflow-import -verify и localdb_test.go).
//
// Драйвер — modernc.org/sqlite: чистый Go, без CGo, чтобы SoundFlow.exe
// собирался и переносился копированием.
package localdb

import (
	"database/sql"
	_ "embed"
	"errors"
	"fmt"
	"sort"
	"strings"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schemaSQL string

// DB — открытая soundflow.db.
type DB struct {
	sql *sql.DB
}

// Open открывает (создаёт при отсутствии) базу по пути и накатывает схему.
// Для read-only доступа рабочего кода передавай ?mode=ro в DSN снаружи.
func Open(path string) (*DB, error) {
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	h, err := sql.Open("sqlite", path+sep+"_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	if _, err := h.Exec(schemaSQL); err != nil {
		h.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	// Мелкие идемпотентные миграции для баз, созданных раньше.
	for _, mig := range []string{
		`ALTER TABLE devices ADD COLUMN transport TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE tracks ADD COLUMN waveform BLOB`,
		// Частота среза спектра (Гц) — сторож по спектру (24.09.2026, Alex TG
		// «научи программу её смотреть спектр и прогони по всем песням»).
		// NULL = ещё не проверяли, 0 = проверили, не определили (тишина/ошибка).
		`ALTER TABLE tracks ADD COLUMN spectral_cutoff_hz INTEGER`,
		// Громкость песни по EBU R128 (LUFS) — для выравнивания громкости на телефоне (26.09.2026,
		// общий вывод пяти разборов). NULL = ещё не считали, LoudnessUnknown = посчитать не вышло.
		`ALTER TABLE tracks ADD COLUMN loudness_lufs REAL`,
		// Настроение по звуку и угаданный жанр (27.09.2026, moodkeeper.go).
		`ALTER TABLE tracks ADD COLUMN mood TEXT`,
		`ALTER TABLE tracks ADD COLUMN genre_guess TEXT`,
		// Удары баса (20 отметок в секунду) — пульсация кнопки «играть» (27.09.2026, basskeeper.go).
		`ALTER TABLE tracks ADD COLUMN bass_env BLOB`,
		`CREATE TABLE IF NOT EXISTS sync_plans (
			device_id TEXT PRIMARY KEY, add_ids TEXT NOT NULL DEFAULT '[]',
			remove_ids TEXT NOT NULL DEFAULT '[]', created_at TEXT NOT NULL DEFAULT '')`,
		`CREATE TABLE IF NOT EXISTS feedback_event (
			id INTEGER PRIMARY KEY AUTOINCREMENT, event_uuid TEXT NOT NULL UNIQUE,
			device_id TEXT NOT NULL DEFAULT '', track_id TEXT NOT NULL DEFAULT '',
			artist TEXT NOT NULL DEFAULT '', event_type TEXT NOT NULL DEFAULT '',
			value REAL NOT NULL DEFAULT 0, reason TEXT NOT NULL DEFAULT '',
			client_ts INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT '')`,
		`CREATE INDEX IF NOT EXISTS feedback_event_track_idx ON feedback_event (track_id)`,
		`CREATE INDEX IF NOT EXISTS feedback_event_artist_idx ON feedback_event (artist)`,
		`CREATE TABLE IF NOT EXISTS taste_cluster (
			layer TEXT NOT NULL DEFAULT 'all', idx INTEGER NOT NULL,
			vec BLOB NOT NULL, n INTEGER NOT NULL DEFAULT 0,
			updated_at TEXT NOT NULL DEFAULT '', PRIMARY KEY (layer, idx))`,
		// Слой 'all' заменён на 'long_term'/'recent' (13.09.2026) — это
		// derived-кэш, не пользовательские данные, безопасно сносить каждый
		// старт (реальные слои соберёт следующий пересчёт).
		`DELETE FROM taste_cluster WHERE layer = 'all'`,
		// Мелкие настройки программы (14.09.2026) — сейчас только папка,
		// которую сама программа проверяет на новые песни при возврате
		// фокуса окна (Alex TG: «опрашивать папку, которую я указал»).
		`CREATE TABLE IF NOT EXISTS app_settings (
			key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '')`,
		// Старые лайки с телефона, которых больше нет в каталоге (Alex TG
		// 15.09.2026 — «библиотеку стёрли, а в избранном на телефоне есть
		// песни, хочу что бы программа их увидела и скачала»). Телефон
		// присылает имена, сервер отсеивает то, что уже в каталоге.
		`CREATE TABLE IF NOT EXISTS phone_missing_favorites (
			normalized_key TEXT PRIMARY KEY, artist TEXT NOT NULL DEFAULT '',
			title TEXT NOT NULL DEFAULT '', reported_at TEXT NOT NULL DEFAULT '')`,
		// «Удалить» во вкладке «Открытия» (Alex TG 20073, 19.09.2026): скрыть песню в списках
		// волны / лайков Яндекса / старых лайков телефона. Только скрытие, см. discover.go.
		`CREATE TABLE IF NOT EXISTS discover_dismissed (
			normalized_key TEXT PRIMARY KEY, artist TEXT NOT NULL DEFAULT '',
			title TEXT NOT NULL DEFAULT '', dismissed_at TEXT NOT NULL DEFAULT '')`,
		// Отпечатки кандидатов «Волны» (21.09.2026, сторож по звуку): считаются один раз на песню, живут несколько дней.
		`CREATE TABLE IF NOT EXISTS wave_vectors (
			yandex_id TEXT PRIMARY KEY, vec BLOB NOT NULL, at TEXT NOT NULL DEFAULT '')`,
		// Возврат песен с телефона на ПК (Alex TG 20261–20267, 21.09.2026): песни, чьи файлы стёрты с компьютера, а на
		// телефоне остались. state: wanted | done | phone_missing | failed; path — прежний путь файла (песня возвращается
		// ровно туда), см. cmd/soundflow/restore.go.
		`CREATE TABLE IF NOT EXISTS restore_request (
			track_id TEXT PRIMARY KEY, file_id TEXT NOT NULL DEFAULT '', path TEXT NOT NULL DEFAULT '',
			size_bytes INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'wanted',
			detail TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '')`,
		// Точный список песен на телефоне (Alex TG 20277–20279, 21.09.2026): телефон присылает его сам, см. inventory.go.
		`CREATE TABLE IF NOT EXISTS phone_inventory (
			device_id TEXT NOT NULL, track_id TEXT NOT NULL, size_bytes INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (device_id, track_id))`,
		// Тексты песен пробовали 26.09.2026 и в тот же день убрали по слову Alex («избавиться от
		// идеи с текстом… удали, не делай бекапов») — таблица, если успела появиться, стирается.
		`DROP TABLE IF EXISTS track_lyrics`,
		// Родные обложки песен из сборников (26.09.2026, cmd/soundflow/origcoverkeeper.go):
		// state 'found' — лежит в original_covers/<id>.jpg; 'none' — не нашлась (повтор через 30 дней).
		`CREATE TABLE IF NOT EXISTS track_original_cover (
			track_id TEXT PRIMARY KEY, state TEXT NOT NULL DEFAULT '', checked_at TEXT NOT NULL DEFAULT '')`,
		`CREATE TABLE IF NOT EXISTS phone_inventory_meta (
			device_id TEXT PRIMARY KEY, at TEXT NOT NULL DEFAULT '',
			count INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0)`,
	} {
		if _, err := h.Exec(mig); err != nil && !strings.Contains(err.Error(), "duplicate column") {
			h.Close()
			return nil, fmt.Errorf("migrate: %w", err)
		}
	}
	return &DB{sql: h}, nil
}

// SQL — доступ к нижележащему *sql.DB (нужен импортёру для batch-вставок).
func (d *DB) SQL() *sql.DB { return d.sql }

func (d *DB) Close() error {
	if d == nil || d.sql == nil {
		return nil
	}
	return d.sql.Close()
}

// CatalogTrack — трек каталога (та же форма, что db.CatalogTrack).
type CatalogTrack struct {
	ID          string `json:"id"`
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	DurationSec int    `json:"duration_sec"`
	ReleaseKind string `json:"release_kind"`
	Explicit    bool   `json:"explicit"`
	CoverURL    string `json:"cover_url"`
	Favorite    bool   `json:"favorite"`
	SizeBytes   int64  `json:"size_bytes"`
	BitrateKbps int    `json:"bitrate_kbps"`
	MimeType    string `json:"mime_type"`
	HasFP       bool   `json:"has_fp"`
}

// то же, что const catalogSelect в internal/db/catalog.go, но на SQLite-диалекте
const catalogSelect = `
	SELECT t.id, t.artist, t.title, t.album,
	       COALESCE(tf.duration_sec, t.duration_sec, 0),
	       t.release_kind, t.explicit, t.cover_url,
	       COALESCE(lm.kind = 'favorite', 0) AS favorite,
	       COALESCE(tf.size_bytes, 0) AS size_bytes,
	       COALESCE(tf.bitrate_kbps, 0),
	       COALESCE(tf.mime_type, ''),
	       (t.feature_vector IS NOT NULL) AS has_fp
	FROM tracks t
	LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
	LEFT JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
	WHERE lm.kind IS NOT 'blocked'`

func (d *DB) scanCatalog(rows *sql.Rows) ([]CatalogTrack, error) {
	defer rows.Close()
	out := make([]CatalogTrack, 0)
	for rows.Next() {
		var t CatalogTrack
		if err := rows.Scan(&t.ID, &t.Artist, &t.Title, &t.Album, &t.DurationSec,
			&t.ReleaseKind, &t.Explicit, &t.CoverURL, &t.Favorite,
			&t.SizeBytes, &t.BitrateKbps, &t.MimeType, &t.HasFP); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// CatalogList — весь каталог, новые сверху. t.id вторым ключом — чтобы порядок
// был устойчивым при одинаковом created_at (иначе выборка с LIMIT «плавает»).
func (d *DB) CatalogList(limit int) ([]CatalogTrack, error) {
	rows, err := d.sql.Query(catalogSelect+`
		ORDER BY t.created_at DESC, t.id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	return d.scanCatalog(rows)
}

// CatalogSearch — поиск по артисту/названию/альбому. Ищем по колонке
// search_text (заранее приведена к нижнему регистру Unicode-aware импортёром),
// т.к. SQLite LIKE/lower() не сворачивают кириллицу.
func (d *DB) CatalogSearch(q string, limit int) ([]CatalogTrack, error) {
	like := "%" + strings.ToLower(q) + "%"
	rows, err := d.sql.Query(catalogSelect+`
		AND t.search_text LIKE ?
		ORDER BY t.created_at DESC, t.id DESC LIMIT ?`, like, limit)
	if err != nil {
		return nil, err
	}
	return d.scanCatalog(rows)
}

// TrackFilePath — канонический путь файла трека.
func (d *DB) TrackFilePath(trackID string) (string, bool, error) {
	var p string
	err := d.sql.QueryRow(
		`SELECT file_path FROM track_files WHERE track_id = ? AND rejected = 0 LIMIT 1`, trackID,
	).Scan(&p)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return p, true, nil
}

// featureVector — отпечаток трека ([]float32) или nil.
func (d *DB) featureVector(trackID string) ([]float32, error) {
	var b []byte
	err := d.sql.QueryRow(`SELECT feature_vector FROM tracks WHERE id = ?`, trackID).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return blobToVec(b), nil
}

// OrderBySimilarity — то же поведение, что db.Pool.OrderBySimilarity, но
// перебором косинуса в памяти на Go (без pgvector). candidateIDs упорядочивает
// по близости к seedID; seedID исключает; кандидатов без отпечатка (или всё,
// если у seed нет отпечатка) оставляет в хвосте в исходном порядке; не даёт
// больше двух треков одного исполнителя подряд.
func (d *DB) OrderBySimilarity(seedID string, candidateIDs []string) (ordered []string, reordered bool, err error) {
	ordered = make([]string, 0, len(candidateIDs))
	seen := map[string]bool{seedID: true}

	seedVec, err := d.featureVector(seedID)
	if err != nil {
		return nil, false, err
	}

	type cand struct {
		id     string
		artist string
		cos    float64
	}
	var byVec []cand

	if len(seedVec) > 0 && len(candidateIDs) > 0 {
		for _, id := range candidateIDs {
			if id == seedID {
				continue
			}
			var artist string
			var b []byte
			e := d.sql.QueryRow(`SELECT artist, feature_vector FROM tracks WHERE id = ?`, id).Scan(&artist, &b)
			if errors.Is(e, sql.ErrNoRows) {
				continue
			}
			if e != nil {
				return nil, false, e
			}
			v := blobToVec(b)
			if len(v) == 0 {
				continue
			}
			cos := cosine(seedVec, v)
			// Тот же трек под другим id (см. duplicateSimThreshold в radio.go)
			// — не показываем как «похожее» самого себя.
			if cos >= duplicateSimThreshold {
				continue
			}
			byVec = append(byVec, cand{id: id, artist: artist, cos: cos})
			seen[id] = true
		}
		// ближе (больше косинус) — раньше; тай-брейк по id для устойчивости
		sort.SliceStable(byVec, func(i, j int) bool {
			if byVec[i].cos != byVec[j].cos {
				return byVec[i].cos > byVec[j].cos
			}
			return byVec[i].id < byVec[j].id
		})
	}

	reordered = len(byVec) > 0

	// не больше двух одного исполнителя подряд (как в Postgres-версии)
	var lastArtist string
	run := 0
	for len(byVec) > 0 {
		pick := 0
		if run >= 2 {
			for i, c := range byVec {
				if !strings.EqualFold(c.artist, lastArtist) {
					pick = i
					break
				}
			}
		}
		c := byVec[pick]
		ordered = append(ordered, c.id)
		byVec = append(byVec[:pick], byVec[pick+1:]...)
		if strings.EqualFold(c.artist, lastArtist) {
			run++
		} else {
			lastArtist = c.artist
			run = 1
		}
	}

	for _, id := range candidateIDs {
		if !seen[id] {
			ordered = append(ordered, id)
			seen[id] = true
		}
	}
	return ordered, reordered, nil
}
