// Command soundflow-tasteeval — проверка на данных Alex: насколько звуковой отпечаток (CNN14) отличает песни,
// которые ему не нравятся («не качать», удалено «не моё»), от тех, что нравятся или просто живут в библиотеке.
// Нужна для «Волны» (Alex TG 20239/20256: дизлайк = свойства песни по звуку, а не исполнитель): прежде чем
// отсеивать кандидатов по звуку, нужно знать, как часто такой отсев ошибается.
//
// Только чтение: базу открывает с mode=ro, ничего не пишет. Оценка «с оставлением группы»: у каждой песни из
// сравнения исключаются песни её же папки (сборник из одной папки звучит одинаково — иначе точность
// получилась бы завышенной).
//
//	go run ./cmd/soundflow-tasteeval [-db E:\soundflow-data\soundflow.db] [-k 3]
package main

import (
	"database/sql"
	"encoding/binary"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	_ "modernc.org/sqlite"

	"soundflow/server/internal/tasteguard"
)

var negMode = "both"

type item struct {
	id, artist, title, group string
	vec                      []float32
	label                    int // -1 не нравится, +1 нравится, 0 обычная живая песня библиотеки
	alive                    bool
}

func main() {
	dbPath := flag.String("db", `E:\soundflow-data\soundflow.db`, "база (открывается только на чтение)")
	k := flag.Int("k", 3, "сколько ближайших соседей усреднять")
	flag.StringVar(&negMode, "neg", "both", "что считать «не нравится»: feedback (явные оценки на телефоне), blocked (метки «не качать») или both")
	flag.Parse()

	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(*dbPath)+"?mode=ro")
	if err != nil {
		fatal(err)
	}
	defer db.Close()
	items := load(db)

	var neg, pos, kept []*item
	for _, it := range items {
		switch {
		case it.label < 0:
			neg = append(neg, it)
		case it.label > 0:
			pos = append(pos, it)
		case it.alive:
			kept = append(kept, it)
		}
	}
	fmt.Printf("не нравится: %d (из них файл есть: %d) | нравится: %d | живая библиотека без оценки: %d\n",
		len(neg), countAlive(neg), len(pos), len(kept))
	if len(neg) < 30 || len(pos)+len(kept) < 100 {
		fatal(fmt.Errorf("слишком мало данных для оценки"))
	}

	ref := append(append([]*item{}, pos...), kept...)
	all := append(append([]*item{}, neg...), ref...)
	sim := simMatrix(all)
	idx := map[*item]int{}
	for i, it := range all {
		idx[it] = i
	}

	// score(x) = среднее k лучших сходств с «не нравится» минус среднее k лучших сходств с «нравится/живая»
	// (обе группы — без песен из папки самого x)
	score := func(x *item) float64 {
		i := idx[x]
		return topMean(sim, i, neg, idx, x.group, *k) - topMean(sim, i, ref, idx, x.group, *k)
	}
	negScores := scores(neg, score)
	posScores := scores(pos, score)
	keptScores := scores(kept, score)
	report(fmt.Sprintf("сырой косинус, k=%d", *k), negScores, posScores, keptScores)
	runFits(neg, pos, kept)

	// разбор по папкам: где отсев работает, где нет
	type fold struct {
		name      string
		n, hit    int
		meanScore float64
	}
	th := quantileAbove(append(append([]float64{}, posScores...), keptScores...), 0.95)
	byF := map[string]*fold{}
	for _, x := range neg {
		f := byF[x.group]
		if f == nil {
			f = &fold{name: x.group}
			byF[x.group] = f
		}
		s := score(x)
		f.n++
		f.meanScore += s
		if s >= th {
			f.hit++
		}
	}
	var folds []*fold
	for _, f := range byF {
		f.meanScore /= float64(f.n)
		folds = append(folds, f)
	}
	sort.Slice(folds, func(i, j int) bool { return folds[i].n > folds[j].n })
	fmt.Printf("\nПапки с «не нравится» (порог для 5%% ошибок = %+.3f):\n", th)
	for i, f := range folds {
		if i >= 12 {
			break
		}
		fmt.Printf("  %3d песен, отсеяно %3d (%3.0f%%), средний счёт %+.3f  %s\n", f.n, f.hit, 100*float64(f.hit)/float64(f.n), f.meanScore, f.name)
	}
}

func load(db *sql.DB) []*item {
	rows, err := db.Query(`
		SELECT t.id, t.artist, t.title, t.feature_vector,
		       COALESCE((SELECT min(file_path) FROM track_files WHERE track_id = t.id AND rejected = 0), ''),
		       COALESCE((SELECT kind FROM legacy_marks WHERE normalized_key = t.normalized_key), ''),
		       COALESCE((SELECT SUM(value) FROM feedback_event WHERE track_id = t.id), 0)
		FROM tracks t WHERE t.feature_vector IS NOT NULL`)
	if err != nil {
		fatal(err)
	}
	defer rows.Close()
	var out []*item
	for rows.Next() {
		var it item
		var blob []byte
		var path, mark string
		var fb float64
		if err := rows.Scan(&it.id, &it.artist, &it.title, &blob, &path, &mark, &fb); err != nil {
			fatal(err)
		}
		if len(blob) != 2048*4 {
			continue
		}
		it.vec = normalize(blob)
		it.group = it.id
		if path != "" {
			it.group = strings.ToLower(filepath.Dir(path))
			if _, err := os.Stat(path); err == nil {
				it.alive = true
			}
		}
		neg := (mark == "blocked" && negMode != "feedback") || (fb < 0 && negMode != "blocked")
		pos := mark == "favorite" || fb > 0
		switch {
		case neg && pos:
			continue // противоречие — в оценку не берём
		case neg:
			it.label = -1
		case pos:
			it.label = 1
		}
		out = append(out, &it)
	}
	return out
}

func normalize(blob []byte) []float32 {
	v := make([]float32, len(blob)/4)
	var n float64
	for i := range v {
		v[i] = math.Float32frombits(binary.LittleEndian.Uint32(blob[i*4:]))
		n += float64(v[i]) * float64(v[i])
	}
	n = math.Sqrt(n)
	if n == 0 {
		return v
	}
	for i := range v {
		v[i] = float32(float64(v[i]) / n)
	}
	return v
}

func simMatrix(all []*item) [][]float32 {
	m := make([][]float32, len(all))
	for i := range m {
		m[i] = make([]float32, len(all))
	}
	for i := range all {
		for j := i; j < len(all); j++ {
			var d float32
			a, b := all[i].vec, all[j].vec
			for t := range a {
				d += a[t] * b[t]
			}
			m[i][j], m[j][i] = d, d
		}
	}
	return m
}

// topMean — среднее k наибольших сходств песни i с песнями группы others, не считая песен из папки group.
func topMean(sim [][]float32, i int, others []*item, idx map[*item]int, group string, k int) float64 {
	var s []float64
	for _, o := range others {
		if o.group == group {
			continue
		}
		s = append(s, float64(sim[i][idx[o]]))
	}
	sort.Sort(sort.Reverse(sort.Float64Slice(s)))
	if len(s) > k {
		s = s[:k]
	}
	if len(s) == 0 {
		return 0
	}
	var sum float64
	for _, v := range s {
		sum += v
	}
	return sum / float64(len(s))
}

func scores(xs []*item, f func(*item) float64) []float64 {
	out := make([]float64, len(xs))
	for i, x := range xs {
		out[i] = f(x)
	}
	return out
}

// auc — вероятность, что счёт случайной «не нравится» выше счёта случайной другой песни.
func auc(a, b []float64) float64 {
	var win float64
	for _, x := range a {
		for _, y := range b {
			switch {
			case x > y:
				win++
			case x == y:
				win += 0.5
			}
		}
	}
	return win / float64(len(a)*len(b))
}

// quantileAbove — значение, ниже которого лежит доля q счётов.
func quantileAbove(xs []float64, q float64) float64 {
	s := append([]float64{}, xs...)
	sort.Float64s(s)
	i := int(math.Ceil(q*float64(len(s)))) - 1
	if i < 0 {
		i = 0
	}
	if i >= len(s) {
		i = len(s) - 1
	}
	return s[i]
}

// share — процент счётов не ниже порога.
func share(xs []float64, th float64) float64 {
	n := 0
	for _, x := range xs {
		if x > th {
			n++
		}
	}
	return 100 * float64(n) / float64(len(xs))
}

func countAlive(xs []*item) int {
	n := 0
	for _, x := range xs {
		if x.alive {
			n++
		}
	}
	return n
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "ошибка:", err)
	os.Exit(1)
}

// report — как счёт отличает «не нравится» от «нравится» и от живой библиотеки.
func report(title string, negScores, posScores, keptScores []float64) {
	fmt.Printf("\n=== %s ===\n", title)
	fmt.Printf("AUC «не нравится» против «нравится»: %.3f\n", auc(negScores, posScores))
	fmt.Printf("AUC «не нравится» против живой библиотеки: %.3f\n", auc(negScores, keptScores))
	fmt.Println("(0.5 — звук не помогает, 1.0 — отличает без ошибок)")
	fmt.Println("Порог отсева: сколько «не нравится» отсеется и сколько «нравится»/библиотеки отсеется по ошибке:")
	for _, fpr := range []float64{0.01, 0.02, 0.05, 0.10} {
		ref := append(append([]float64{}, posScores...), keptScores...)
		th := quantileAbove(ref, 1-fpr)
		fmt.Printf("  ошибок среди нравящихся/библиотеки %4.1f%% → порог %+.3f: отсеет %5.1f%% из «не нравится» (нравится: %4.1f%%, библиотека: %4.1f%%)\n",
			fpr*100, th, share(negScores, th), share(posScores, th), share(keptScores, th))
	}
}

// runFits — линейный разделитель из tasteguard (тот же, что включает фильтр «Волны»): проверка по папкам для каждой λ
// и итоговое решение сторожа.
func runFits(neg, pos, kept []*item) {
	var samples []tasteguard.Sample
	add := func(xs []*item, n, p bool) {
		for _, x := range xs {
			samples = append(samples, tasteguard.Sample{Vec: x.vec, Group: x.group, Neg: n, Pos: p})
		}
	}
	add(neg, true, false)
	add(pos, false, true)
	add(kept, false, false)
	rep, fits, err := tasteguard.Evaluate(samples)
	if err != nil {
		fatal(err)
	}
	for _, f := range fits {
		nn, np := len(neg), len(pos)
		report(fmt.Sprintf("линейный разделитель по звуку (λ=%g, проверка по папкам)", f.Lambda), f.OOF[:nn], f.OOF[nn:nn+np], f.OOF[nn+np:])
	}
	fmt.Printf("\nРешение сторожа (tasteguard): включён=%v; лучшая λ=%g; точность против «нравится» %.2f, против библиотеки %.2f; порог %+.3f ловит %.0f%% «не нравится»\n",
		rep.Enabled, rep.Lambda, rep.AUCPos, rep.AUCKept, rep.Threshold, 100*rep.Catch)
	if rep.Reason != "" {
		fmt.Println("Причина:", rep.Reason)
	}
}
