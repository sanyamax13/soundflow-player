// soundflow-fingerprint — пересчёт звукового отпечатка (PANNs CNN14) на Go
// через onnxruntime.dll + ffmpeg, запись в soundflow.db. Заменяет Python-сайдкар
// для feature_vector (шаг 3 плана).
//
//	go run ./cmd/soundflow-fingerprint -db soundflow.db -assets <dir> -fg soundflow-fg
//	go run ./cmd/soundflow-fingerprint -db soundflow.db -assets <dir> -fg soundflow-fg -compare -sample 60
//
// -compare: НЕ пишет в базу; для выборки seed-треков считает Go-вектор и
// сверяет список «похожих», построенный по старым (импортированным из Postgres)
// векторам и по свежим Go-векторам того же пула. Печатает совпадение топ-K.
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"

	"soundflow/server/internal/inference"
)

type job struct{ id, path string }

func main() {
	dbPath := flag.String("db", "soundflow.db", "путь к soundflow.db")
	assets := flag.String("assets", "", "папка с onnxruntime.dll и cnn14.onnx")
	fg := flag.String("fg", "", "ssh-хост fg — тянуть аудио оттуда (scp). Пусто — брать локально по file_path")
	audioRoot := flag.String("audio-root", "", "заменить префикс E:\\soundflow-data на этот локальный путь")
	limit := flag.Int("limit", 0, "0 = все")
	offset := flag.Int("offset", 0, "пропустить первые N (для докачки)")
	compare := flag.Bool("compare", false, "не писать в базу, сверить списки похожих")
	sample := flag.Int("sample", 60, "сколько seed-треков для -compare")
	workers := flag.Int("workers", 2, "параллельные загрузка+декод (сам прогон модели один)")
	flag.Parse()

	eng, err := inference.Open(*assets)
	if err != nil {
		log.Fatalf("модель: %v", err)
	}
	defer eng.Close()

	db, err := sql.Open("sqlite", *dbPath+"?_pragma=busy_timeout(5000)")
	if err != nil {
		log.Fatalf("sqlite: %v", err)
	}
	defer db.Close()

	rows, err := db.Query(`
		SELECT t.id, tf.file_path
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		ORDER BY t.id`)
	if err != nil {
		log.Fatal(err)
	}

	var jobs []job
	for rows.Next() {
		var j job
		if err := rows.Scan(&j.id, &j.path); err != nil {
			log.Fatal(err)
		}
		jobs = append(jobs, j)
	}
	rows.Close()
	if *offset > 0 && *offset < len(jobs) {
		jobs = jobs[*offset:]
	}
	if *limit > 0 && *limit < len(jobs) {
		jobs = jobs[:*limit]
	}
	fmt.Printf("к обработке: %d треков\n", len(jobs))

	fetch := newFetcher(*fg, *audioRoot)

	if *compare {
		runCompare(db, eng, fetch, jobs, *sample, *workers)
		return
	}

	// пересчёт + запись
	var done, failed int64
	t0 := time.Now()
	pcmCh := make(chan struct {
		id  string
		pcm []float32
		err error
	}, *workers)
	var wg sync.WaitGroup
	in := make(chan job)
	for w := 0; w < *workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range in {
				pcm, err := fetch.pcm(j.path)
				pcmCh <- struct {
					id  string
					pcm []float32
					err error
				}{j.id, pcm, err}
			}
		}()
	}
	go func() {
		for _, j := range jobs {
			in <- j
		}
		close(in)
		wg.Wait()
		close(pcmCh)
	}()

	upd, _ := db.Prepare(`UPDATE tracks SET feature_vector = ? WHERE id = ?`)
	defer upd.Close()
	for r := range pcmCh {
		if r.err != nil {
			failed++
			if failed <= 15 {
				fmt.Printf("  FAIL %s: %v\n", r.id, r.err)
			}
			continue
		}
		emb, err := eng.Embed(r.pcm)
		if err != nil {
			failed++
			fmt.Printf("  FAIL %s (embed): %v\n", r.id, err)
			continue
		}
		if _, err := upd.Exec(floatsToBlob(emb), r.id); err != nil {
			log.Fatalf("запись %s: %v", r.id, err)
		}
		done++
		if done%200 == 0 {
			rate := float64(done) / time.Since(t0).Seconds()
			fmt.Printf("  %d/%d  %.1f/с  ETA %.0f мин\n",
				done, len(jobs), rate, float64(int64(len(jobs))-done)/rate/60)
		}
	}
	fmt.Printf("готово: записано %d, ошибок %d, за %s\n",
		done, failed, time.Since(t0).Round(time.Second))
}

// ---------------- получение аудио ----------------

type fetcher struct {
	fg        string
	audioRoot string
	tmp       string
}

func newFetcher(fg, audioRoot string) *fetcher {
	d, _ := os.MkdirTemp("", "sf-fp-")
	return &fetcher{fg: fg, audioRoot: audioRoot, tmp: d}
}

func (f *fetcher) pcm(canon string) ([]float32, error) {
	// локальный путь?
	local := canon
	if f.audioRoot != "" {
		local = remap(canon, f.audioRoot)
	}
	if f.fg == "" {
		if _, err := os.Stat(local); err != nil {
			return nil, fmt.Errorf("нет файла: %s", local)
		}
		return inference.DecodePCM(local)
	}
	// тянем с fg в temp, декодим, удаляем
	rp := fgPath(canon)
	if rp == "" {
		return nil, fmt.Errorf("путь не мапится: %s", canon)
	}
	dst := filepath.Join(f.tmp, sanitize(canon))
	cmd := exec.Command("scp", "-o", "BatchMode=yes", "-q", f.fg+":"+rp, dst)
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("scp: %v: %s", err, strings.TrimSpace(string(out)))
	}
	defer os.Remove(dst)
	return inference.DecodePCM(dst)
}

func remap(canon, root string) string {
	low := strings.ToLower(strings.ReplaceAll(canon, "/", "\\"))
	const pre = `e:\soundflow-data`
	if strings.HasPrefix(low, pre) {
		return filepath.Join(root, canon[len(pre):])
	}
	return canon
}

func fgPath(canon string) string {
	low := strings.ToLower(strings.ReplaceAll(canon, "/", "\\"))
	for _, p := range []struct{ pre, sub string }{
		{`e:\soundflow-data\cache`, "cache"},
		{`e:\soundflow-data\music`, "music"},
	} {
		if strings.HasPrefix(low, p.pre) {
			rest := strings.ReplaceAll(canon[len(p.pre):], "\\", "/")
			return "D:/SoundFlow/" + p.sub + "/" + strings.TrimPrefix(rest, "/")
		}
	}
	return ""
}

func sanitize(s string) string {
	r := strings.NewReplacer("/", "_", "\\", "_", ":", "_", " ", "_", "*", "_", "?", "_", "\"", "_")
	b := r.Replace(s)
	if len(b) > 120 {
		b = b[len(b)-120:]
	}
	return b
}

// ---------------- -compare ----------------

func runCompare(db *sql.DB, eng *inference.Engine, f *fetcher, jobs []job, sample, workers int) {
	// старые (импортированные) вектора для всего пула
	old := map[string][]float32{}
	rows, _ := db.Query(`SELECT id, feature_vector FROM tracks WHERE feature_vector IS NOT NULL`)
	for rows.Next() {
		var id string
		var b []byte
		_ = rows.Scan(&id, &b)
		old[id] = blobToFloats(b)
	}
	rows.Close()

	// Go-вектора для пула (берём первые sample*4, но не больше)
	pool := jobs
	capN := sample * 5
	if len(pool) > capN {
		pool = pool[:capN]
	}
	fmt.Printf("-compare: считаю Go-вектора для пула %d…\n", len(pool))
	goVec := map[string][]float32{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	in := make(chan job)
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range in {
				pcm, err := f.pcm(j.path)
				if err != nil {
					continue
				}
				mu.Lock()
				emb, err := eng.Embed(pcm)
				mu.Unlock()
				if err != nil {
					continue
				}
				mu.Lock()
				goVec[j.id] = emb
				mu.Unlock()
			}
		}()
	}
	for _, j := range pool {
		in <- j
	}
	close(in)
	wg.Wait()

	// общий набор id, где есть и старый, и новый вектор
	var ids []string
	for id := range goVec {
		if old[id] != nil {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	if len(ids) < 10 {
		fmt.Printf("мало данных для сравнения (%d)\n", len(ids))
		return
	}
	seeds := ids
	if len(seeds) > sample {
		seeds = seeds[:sample]
	}
	const k = 20
	tot, worst := 0, k
	for _, s := range seeds {
		po := rank(s, ids, func(x string) []float32 { return old[x] })
		gr := rank(s, ids, func(x string) []float32 { return goVec[x] })
		n := imin(k, len(po), len(gr))
		ov := ovl(po[:n], gr[:n])
		tot += ov
		if ov < worst {
			worst = ov
		}
	}
	avg := float64(tot) / float64(len(seeds))
	fmt.Printf("-compare: %d seed-ов, совпадение топ-%d соседей старое↔Go: среднее %.2f/%d, худшее %d/%d\n",
		len(seeds), k, avg, k, worst, k)
}

func rank(seed string, all []string, vec func(string) []float32) []string {
	sv := vec(seed)
	type sc struct {
		id string
		c  float64
	}
	var arr []sc
	for _, id := range all {
		if id == seed || vec(id) == nil {
			continue
		}
		arr = append(arr, sc{id, cosf(sv, vec(id))})
	}
	sort.Slice(arr, func(i, j int) bool { return arr[i].c > arr[j].c })
	out := make([]string, len(arr))
	for i, s := range arr {
		out[i] = s.id
	}
	return out
}

func ovl(a, b []string) int {
	m := map[string]bool{}
	for _, x := range a {
		m[x] = true
	}
	n := 0
	for _, x := range b {
		if m[x] {
			n++
		}
	}
	return n
}

func cosf(a, b []float32) float64 {
	var d, na, nb float64
	for i := range a {
		d += float64(a[i]) * float64(b[i])
		na += float64(a[i]) * float64(a[i])
		nb += float64(b[i]) * float64(b[i])
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return d / (math.Sqrt(na) * math.Sqrt(nb))
}

func imin(xs ...int) int {
	m := xs[0]
	for _, x := range xs[1:] {
		if x < m {
			m = x
		}
	}
	return m
}

// ---------------- BLOB <-> []float32 ----------------

func floatsToBlob(v []float32) []byte {
	b := make([]byte, len(v)*4)
	for i, f := range v {
		u := math.Float32bits(f)
		b[i*4+0], b[i*4+1], b[i*4+2], b[i*4+3] = byte(u), byte(u>>8), byte(u>>16), byte(u>>24)
	}
	return b
}

func blobToFloats(b []byte) []float32 {
	if len(b)%4 != 0 {
		return nil
	}
	v := make([]float32, len(b)/4)
	for i := range v {
		u := uint32(b[i*4]) | uint32(b[i*4+1])<<8 | uint32(b[i*4+2])<<16 | uint32(b[i*4+3])<<24
		v[i] = math.Float32frombits(u)
	}
	return v
}
