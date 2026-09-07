// soundflow-import — одноразовый перенос каталога из PostgreSQL в лёгкую
// soundflow.db (SQLite). Рабочий сервер и Postgres не трогаются: Postgres
// читаем только на чтение, пишем в новый файл.
//
//	go run ./cmd/soundflow-import -pg "postgres://..." -out soundflow.db
//	go run ./cmd/soundflow-import -pg "postgres://..." -out soundflow.db -verify
//
// По каждой таблице печатает число строк и контрольную сумму (XOR FNV-1a по
// строкам — от порядка обхода не зависит) с обеих сторон. -verify дополнительно
// прогоняет «поиск» и «похожие треки» на обеих базах и сверяет результат.
package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"hash/fnv"
	"log"
	"math"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"soundflow/server/internal/localdb"
)

// Порядок важен: tracks раньше track_files (внешний ключ), и так далее.
var tables = []tableCopy{
	{
		name: "tracks",
		cols: []string{"id", "artist", "title", "album", "year", "duration_sec",
			"language", "genre_tags", "release_kind", "explicit", "is_alt_version",
			"cover_path", "cover_ok", "normalized_key", "energy", "valence",
			"feature_vector", "cover_url", "created_at"},
		sel: `SELECT id,artist,title,album,year,duration_sec,language,genre_tags,
		             release_kind,explicit,is_alt_version,cover_path,cover_ok,
		             normalized_key,energy,valence,feature_vector::text,cover_url,created_at
		      FROM tracks`,
		vecCol:   "feature_vector",
		extraCol: "search_text",
		// vals[1]=artist, [2]=title, [3]=album; Unicode-aware lower — в SQLite нет
		extraVal: func(vals []any) any {
			get := func(i int) string { s, _ := vals[i].(string); return s }
			return strings.ToLower(get(1) + " " + get(2) + " " + get(3))
		},
	},
	{
		name: "track_files",
		cols: []string{"id", "track_id", "normalized_key", "file_path", "mime_type",
			"bitrate_kbps", "size_bytes", "duration_sec", "source", "quality_tier",
			"loudness_lufs", "true_peak_db", "rejected", "reject_reason", "downloaded_at"},
		sel: `SELECT id,track_id,normalized_key,file_path,mime_type,bitrate_kbps,
		             size_bytes,duration_sec,source,quality_tier,loudness_lufs,
		             true_peak_db,rejected,reject_reason,downloaded_at
		      FROM track_files`,
	},
	{
		name: "devices",
		cols: []string{"id", "name", "app_version", "music_bytes", "last_sync_at", "created_at"},
		sel:  `SELECT id,name,app_version,music_bytes,last_sync_at,created_at FROM devices`,
	},
	{
		name: "sync_events",
		cols: []string{"event_uuid", "device_id", "kind", "track_id", "payload", "client_ts", "applied_at"},
		sel:  `SELECT event_uuid,device_id,kind,track_id,payload::text,client_ts,applied_at FROM sync_events`,
	},
	{
		name: "server_log",
		cols: []string{"id", "at", "kind", "artist", "title", "detail", "bytes"},
		sel:  `SELECT id,at,kind,artist,title,detail,bytes FROM server_log`,
	},
	{
		name: "legacy_marks",
		cols: []string{"normalized_key", "kind", "artist", "title", "marked_at"},
		sel:  `SELECT normalized_key,kind,artist,title,marked_at FROM legacy_marks`,
	},
	{
		name: "rejected_track_files",
		cols: []string{"id", "normalized_key", "source_url", "provider", "artist", "title", "reason", "rejected_at"},
		sel:  `SELECT id,normalized_key,source_url,provider,artist,title,reason,rejected_at FROM rejected_track_files`,
	},
}

func main() {
	pgURL := flag.String("pg", os.Getenv("DATABASE_URL"), "PostgreSQL DSN (источник)")
	out := flag.String("out", "soundflow.db", "путь к soundflow.db (SQLite, назначение)")
	verify := flag.Bool("verify", false, "после импорта сверить поиск/похожие на обеих базах")
	sample := flag.Int("sample", 50, "сколько seed-треков брать для -verify")
	flag.Parse()

	if *pgURL == "" {
		log.Fatal("нужен -pg или DATABASE_URL")
	}
	ctx := context.Background()

	pool, err := pgxpool.New(ctx, *pgURL)
	if err != nil {
		log.Fatalf("Postgres: %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("Postgres ping: %v", err)
	}

	if err := os.Remove(*out); err != nil && !os.IsNotExist(err) {
		log.Fatalf("не удалить старую %s: %v", *out, err)
	}
	for _, suf := range []string{"-wal", "-shm"} {
		_ = os.Remove(*out + suf)
	}

	ldb, err := localdb.Open(*out)
	if err != nil {
		log.Fatalf("SQLite: %v", err)
	}
	defer ldb.Close()

	start := time.Now()
	fail := false
	for _, tbl := range tables {
		liteStat, err := tbl.run(ctx, pool, ldb.SQL())
		if err != nil {
			log.Fatalf("таблица %s: %v", tbl.name, err)
		}
		pgStat, err := tbl.checksumPG(ctx, pool)
		if err != nil {
			log.Fatalf("checksum PG %s: %v", tbl.name, err)
		}
		match := "OK"
		if pgStat.count != liteStat.count || pgStat.xor != liteStat.xor {
			match, fail = "!!! РАСХОЖДЕНИЕ", true
		}
		_, _ = ldb.SQL().Exec(
			`INSERT OR REPLACE INTO import_meta(table_name,row_count,checksum,imported_at) VALUES(?,?,?,?)`,
			tbl.name, liteStat.count, fmt.Sprintf("%016x", liteStat.xor),
			time.Now().UTC().Format(time.RFC3339))
		fmt.Printf("  %-22s PG %6d / SQLite %6d   sum %016x   %s\n",
			tbl.name, pgStat.count, liteStat.count, liteStat.xor, match)
	}
	fmt.Printf("импорт за %s -> %s\n", time.Since(start).Round(time.Millisecond), *out)
	if fail {
		log.Fatal("контрольные суммы не сошлись — база не годна")
	}

	if *verify {
		if err := runVerify(ctx, pool, ldb, *sample); err != nil {
			log.Fatalf("verify: %v", err)
		}
	}
}

// ---------------- перенос таблицы ----------------

type tableCopy struct {
	name     string
	cols     []string
	sel      string
	vecCol   string          // колонка-вектор (pgvector ::text -> BLOB), либо ""
	extraCol string          // доп. вычисляемая колонка в SQLite (нет в Postgres), либо ""
	extraVal func([]any) any // как её посчитать из строки Postgres
}

type stat struct {
	count int64
	xor   uint64
}

func (t tableCopy) run(ctx context.Context, pg *pgxpool.Pool, lite *sql.DB) (stat, error) {
	rows, err := pg.Query(ctx, t.sel)
	if err != nil {
		return stat{}, err
	}
	defer rows.Close()

	insCols := append([]string(nil), t.cols...)
	if t.extraCol != "" {
		insCols = append(insCols, t.extraCol)
	}
	ph := strings.TrimSuffix(strings.Repeat("?,", len(insCols)), ",")
	ins := fmt.Sprintf("INSERT INTO %s (%s) VALUES (%s)", t.name, strings.Join(insCols, ","), ph)

	var st stat
	tx, err := lite.Begin()
	if err != nil {
		return stat{}, err
	}
	stmt, err := tx.Prepare(ins)
	if err != nil {
		_ = tx.Rollback()
		return stat{}, err
	}
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			_ = tx.Rollback()
			return stat{}, err
		}
		args := make([]any, 0, len(vals)+1)
		hashParts := make([]string, 0, len(vals)*2)
		for i, v := range vals {
			col := t.cols[i]
			var lite any
			if col == t.vecCol {
				lite = vecBlob(v)
			} else {
				lite = toLite(v)
			}
			args = append(args, lite)
			hashParts = append(hashParts, col, s(lite))
		}
		if t.extraCol != "" {
			args = append(args, t.extraVal(vals)) // в контрольную сумму не идёт
		}
		if _, err := stmt.Exec(args...); err != nil {
			_ = tx.Rollback()
			return stat{}, fmt.Errorf("insert %s: %w", t.name, err)
		}
		st.count++
		st.xor ^= rowHash(hashParts...)
	}
	if err := rows.Err(); err != nil {
		_ = tx.Rollback()
		return stat{}, err
	}
	_ = stmt.Close()
	if err := tx.Commit(); err != nil {
		return stat{}, err
	}
	return st, nil
}

// checksumPG считает ту же XOR-FNV сумму по Postgres, приводя значения к тем же
// «литным» типам, что легли в SQLite.
func (t tableCopy) checksumPG(ctx context.Context, pg *pgxpool.Pool) (stat, error) {
	rows, err := pg.Query(ctx, t.sel)
	if err != nil {
		return stat{}, err
	}
	defer rows.Close()
	var st stat
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			return stat{}, err
		}
		hashParts := make([]string, 0, len(vals)*2)
		for i, v := range vals {
			col := t.cols[i]
			var lite any
			if col == t.vecCol {
				lite = vecBlob(v)
			} else {
				lite = toLite(v)
			}
			hashParts = append(hashParts, col, s(lite))
		}
		st.count++
		st.xor ^= rowHash(hashParts...)
	}
	return st, rows.Err()
}

// ---------------- преобразование значений ----------------

// toLite приводит значение из pgx к тому, что кладём в SQLite:
// строки/числа как есть, bool -> 0/1, время -> RFC3339-строка, text[] -> JSON.
func toLite(v any) any {
	switch x := v.(type) {
	case nil:
		return nil
	case bool:
		if x {
			return int64(1)
		}
		return int64(0)
	case time.Time:
		return x.UTC().Format(time.RFC3339Nano)
	case int32:
		return int64(x)
	case int16:
		return int64(x)
	case int64, string, float64, float32, []byte:
		return x
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			parts[i], _ = e.(string)
		}
		b, _ := json.Marshal(parts)
		return string(b)
	case []string:
		b, _ := json.Marshal(x)
		return string(b)
	default:
		return fmt.Sprintf("%v", x)
	}
}

// vecBlob: значение колонки-вектора (pgvector, пришёл как text "[...]" или nil)
// -> BLOB little-endian float32, либо nil.
func vecBlob(v any) any {
	txt, ok := v.(string)
	if !ok || txt == "" {
		return nil
	}
	f := parsePGVec(txt)
	if len(f) == 0 {
		return nil
	}
	return floatsToBlob(f)
}

func parsePGVec(s string) []float32 {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "[")
	s = strings.TrimSuffix(s, "]")
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]float32, 0, len(parts))
	for _, p := range parts {
		x, err := strconv.ParseFloat(strings.TrimSpace(p), 32)
		if err != nil {
			return nil
		}
		out = append(out, float32(x))
	}
	return out
}

func floatsToBlob(v []float32) []byte {
	b := make([]byte, len(v)*4)
	for i, f := range v {
		u := math.Float32bits(f)
		b[i*4+0] = byte(u)
		b[i*4+1] = byte(u >> 8)
		b[i*4+2] = byte(u >> 16)
		b[i*4+3] = byte(u >> 24)
	}
	return b
}

// s — нормализованное строковое представление литного значения для хеша.
func s(v any) string {
	switch x := v.(type) {
	case nil:
		return "\x00"
	case string:
		return x
	case int64:
		return strconv.FormatInt(x, 10)
	case float64:
		return strconv.FormatFloat(x, 'g', -1, 64)
	case float32:
		return strconv.FormatFloat(float64(x), 'g', -1, 32)
	case []byte:
		sum := sha256.Sum256(x)
		return "b:" + hex.EncodeToString(sum[:12])
	default:
		return fmt.Sprintf("%v", x)
	}
}

func rowHash(fields ...string) uint64 {
	h := fnv.New64a()
	for _, f := range fields {
		_, _ = h.Write([]byte(f))
		_, _ = h.Write([]byte{0x1f})
	}
	return h.Sum64()
}

// ---------------- verify: поиск и похожие на обеих базах ----------------

func runVerify(ctx context.Context, pg *pgxpool.Pool, ldb *localdb.DB, sample int) error {
	fmt.Println("verify:")

	// 1) поиск по нескольким терминам
	for _, term := range []string{"love", "the", "remix", "ноч", "би-2", "a"} {
		pgIDs, err := pgSearch(ctx, pg, term, 50)
		if err != nil {
			return err
		}
		liteRows, err := ldb.CatalogSearch(term, 50)
		if err != nil {
			return err
		}
		liteIDs := ids(liteRows)
		if !sameSet(pgIDs, liteIDs) {
			return fmt.Errorf("поиск %q: PG %d vs SQLite %d, множества расходятся",
				term, len(pgIDs), len(liteIDs))
		}
		fmt.Printf("  поиск %-8q %d совпадений — OK\n", term, len(pgIDs))
	}

	// 2) похожие треки: seed + случайные кандидаты, сверяем порядок
	seeds, err := randomTracksWithVec(ctx, pg, sample)
	if err != nil {
		return err
	}
	pool2, err := allTrackIDs(ctx, pg)
	if err != nil {
		return err
	}
	mism := 0
	for _, seed := range seeds {
		cands := pickCandidates(pool2, seed, 60)
		pgOrd, err := pgOrderBySimilarity(ctx, pg, seed, cands)
		if err != nil {
			return err
		}
		liteOrd, _, err := ldb.OrderBySimilarity(seed, cands)
		if err != nil {
			return err
		}
		if !equalSlice(pgOrd, liteOrd) {
			mism++
			if mism <= 3 {
				fmt.Printf("  похожие seed=%s расходятся:\n    PG   %v\n    lite %v\n",
					seed, head(pgOrd, 8), head(liteOrd, 8))
			}
		}
	}
	fmt.Printf("  похожие: %d seed-ов, расхождений %d\n", len(seeds), mism)
	if mism > 0 {
		return fmt.Errorf("порядок «похожих» разошёлся на %d из %d", mism, len(seeds))
	}
	fmt.Println("verify: OK — SQLite даёт то же, что Postgres")
	return nil
}

func pgSearch(ctx context.Context, pg *pgxpool.Pool, q string, limit int) ([]string, error) {
	rows, err := pg.Query(ctx, `
		SELECT t.id
		FROM tracks t
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		LEFT JOIN track_files tf ON tf.track_id = t.id AND NOT tf.rejected
		WHERE lm.kind IS DISTINCT FROM 'blocked'
		  AND (lower(t.artist||' '||t.title||' '||t.album) LIKE '%'||lower($2)||'%')
		ORDER BY t.created_at DESC, t.id DESC LIMIT $1`, limit, q)
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

func pgOrderBySimilarity(ctx context.Context, pg *pgxpool.Pool, seed string, cands []string) ([]string, error) {
	seen := map[string]bool{seed: true}
	type ia struct{ id, artist string }
	var byVec []ia
	rows, err := pg.Query(ctx, `
		WITH s AS (SELECT feature_vector AS v FROM tracks WHERE id = $1)
		SELECT t.id, t.artist
		FROM tracks t, s
		WHERE t.id = ANY($2) AND t.id <> $1
		  AND t.feature_vector IS NOT NULL AND s.v IS NOT NULL
		ORDER BY t.feature_vector <=> s.v`, seed, cands)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var x ia
		if err := rows.Scan(&x.id, &x.artist); err != nil {
			rows.Close()
			return nil, err
		}
		byVec = append(byVec, x)
		seen[x.id] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	var out []string
	var lastArtist string
	run := 0
	for len(byVec) > 0 {
		pick := 0
		if run >= 2 {
			for i, x := range byVec {
				if !strings.EqualFold(x.artist, lastArtist) {
					pick = i
					break
				}
			}
		}
		x := byVec[pick]
		out = append(out, x.id)
		byVec = append(byVec[:pick], byVec[pick+1:]...)
		if strings.EqualFold(x.artist, lastArtist) {
			run++
		} else {
			lastArtist = x.artist
			run = 1
		}
	}
	for _, id := range cands {
		if !seen[id] {
			out = append(out, id)
			seen[id] = true
		}
	}
	return out, nil
}

func randomTracksWithVec(ctx context.Context, pg *pgxpool.Pool, n int) ([]string, error) {
	rows, err := pg.Query(ctx,
		`SELECT id FROM tracks WHERE feature_vector IS NOT NULL ORDER BY random() LIMIT $1`, n)
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

func allTrackIDs(ctx context.Context, pg *pgxpool.Pool) ([]string, error) {
	rows, err := pg.Query(ctx, `SELECT id FROM tracks ORDER BY id`)
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

func pickCandidates(pool []string, seed string, n int) []string {
	// детерминированно от seed — чтобы прогон повторялся
	h := fnv.New64a()
	_, _ = h.Write([]byte(seed))
	r := int64(h.Sum64() & 0x7fffffffffffffff)
	step := len(pool)/max(n, 1) + 1
	out := make([]string, 0, n+1)
	out = append(out, seed)
	for i := 0; len(out) < n+1 && i < len(pool); i++ {
		idx := int((r + int64(i)*int64(step)) % int64(len(pool)))
		if idx < 0 {
			idx += len(pool)
		}
		if pool[idx] != seed {
			out = append(out, pool[idx])
		}
	}
	return out
}

// ---------------- мелочи ----------------

func ids(rows []localdb.CatalogTrack) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.ID
	}
	return out
}

func sameSet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	ma := map[string]int{}
	for _, x := range a {
		ma[x]++
	}
	for _, x := range b {
		ma[x]--
	}
	for _, v := range ma {
		if v != 0 {
			return false
		}
	}
	return true
}

func equalSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func head(s []string, n int) []string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
