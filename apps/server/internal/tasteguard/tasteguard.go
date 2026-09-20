// Package tasteguard — «сторож по звуку» для «Волны» (Alex TG 20239/20259, 21.09.2026): отсеивать кандидатов,
// которые по звуку похожи на то, что Alex не любит, — но ТОЛЬКО когда это действительно надёжно.
//
// Проверка на живых данных 21.09.2026 показала, что звуковой отпечаток (CNN14) «не нравится» почти не отличает
// от «нравится» и обычной библиотеки (точность 0,55–0,66, 0,5 — монетка): метки «не нравится» у Alex — в основном
// песни из целиком выброшенных сборников, а не свойство звука. Поэтому сторож сам, раз в неделю, проверяет себя
// на свежих оценках Alex и включается, только когда точность (AUC) дошла до MinAUC; пока не дошла — фильтра нет.
//
// Модель — линейный разделитель: гребневая регрессия в двойственной форме на z-оценках отпечатка; проверка —
// пятикратная перекрёстная по группам-папкам (песни одной папки, например сборника, никогда не попадают одновременно
// в обучение и в проверку — иначе точность получилась бы завышенной, ведь сборник звучит одинаково).
package tasteguard

import (
	"errors"
	"fmt"
	"hash/fnv"
	"math"
	"sort"
)

const (
	MinNeg       = 100  // «не нравится» — меньше не строим
	MinRef       = 300  // «нравится» + обычные песни — меньше не строим
	MinAUC       = 0.80 // Alex TG 20259: включать «от 80 %»
	MinCatch     = 0.25 // фильтр обязан ловить хотя бы четверть «не нравится», иначе смысла нет
	FalseReject  = 0.02 // сколько нравящегося/обычного можно отсеять по ошибке
	minPosForAUC = 10   // меньше «нравится» — сравнивать с ними бессмысленно, смотрим только обычную библиотеку
	folds        = 5
)

// Lambdas — силы регуляризации, из которых при проверке выбирается лучшая.
var Lambdas = []float64{0.3, 3, 30}

// Sample — песня с отпечатком. Neg — «не нравится», Pos — «нравится», обе false — обычная песня библиотеки.
type Sample struct {
	Vec   []float32
	Group string // папка: песни одной группы не участвуют друг в друге при проверке
	Neg   bool
	Pos   bool
}

// Fit — результат проверки для одной λ. OOF — счёт каждой песни, полученный моделью, которая её (и её папку) не видела.
type Fit struct {
	Lambda  float64
	AUCPos  float64 // «не нравится» против «нравится»; NaN, если «нравится» слишком мало
	AUCKept float64 // «не нравится» против обычной библиотеки
	OOF     []float64
}

// MinAUCOf — худшая из двух точностей (NaN пропускается).
func (f Fit) MinAUCOf() float64 {
	switch {
	case math.IsNaN(f.AUCPos):
		return f.AUCKept
	case math.IsNaN(f.AUCKept):
		return f.AUCPos
	}
	return math.Min(f.AUCPos, f.AUCKept)
}

// Report — итог еженедельной проверки.
type Report struct {
	Neg, Pos, Kept  int
	Lambda          float64
	AUCPos, AUCKept float64
	Threshold       float64 // счёт, с которого кандидата отсеиваем (ошибка не больше FalseReject)
	Catch           float64 // какую долю «не нравится» этот порог отсеивает (0…1)
	Enabled         bool
	Reason          string // почему не включено (по-русски, для окна)
}

// prepared — нормированные и стандартизованные отпечатки + всё нужное, чтобы оценить новую песню так же.
type prepared struct {
	mean, std []float64
	z         [][]float64
	d         int
}

func prepare(samples []Sample) (*prepared, error) {
	if len(samples) == 0 {
		return nil, errors.New("нет песен")
	}
	d := len(samples[0].Vec)
	if d == 0 {
		return nil, errors.New("пустой отпечаток")
	}
	p := &prepared{d: d, mean: make([]float64, d), std: make([]float64, d), z: make([][]float64, len(samples))}
	norm := make([][]float64, len(samples))
	for i, s := range samples {
		if len(s.Vec) != d {
			return nil, fmt.Errorf("у песни %d длина отпечатка %d, ждали %d", i, len(s.Vec), d)
		}
		norm[i] = l2(s.Vec)
		for t, v := range norm[i] {
			p.mean[t] += v
		}
	}
	n := float64(len(samples))
	for t := range p.mean {
		p.mean[t] /= n
	}
	for _, row := range norm {
		for t, v := range row {
			dv := v - p.mean[t]
			p.std[t] += dv * dv
		}
	}
	for t := range p.std {
		p.std[t] = math.Sqrt(p.std[t]/n) + 1e-9
	}
	for i, row := range norm {
		z := make([]float64, d)
		for t, v := range row {
			z[t] = (v - p.mean[t]) / p.std[t]
		}
		p.z[i] = z
	}
	return p, nil
}

func l2(v []float32) []float64 {
	out := make([]float64, len(v))
	var n float64
	for i, x := range v {
		out[i] = float64(x)
		n += out[i] * out[i]
	}
	n = math.Sqrt(n)
	if n == 0 {
		return out
	}
	for i := range out {
		out[i] /= n
	}
	return out
}

func kernel(z [][]float64, d int) [][]float64 {
	n := len(z)
	K := make([][]float64, n)
	for i := range K {
		K[i] = make([]float64, n)
	}
	for i := 0; i < n; i++ {
		for j := i; j < n; j++ {
			var s float64
			a, b := z[i], z[j]
			for t := 0; t < d; t++ {
				s += a[t] * b[t]
			}
			s /= float64(d)
			K[i][j], K[j][i] = s, s
		}
	}
	return K
}

// classWeight — вес песни в обучении: два класса («не нравится» и остальные) весят поровну.
func classWeight(m, cn, cr int, neg bool) float64 {
	if neg {
		return float64(m) / (2 * float64(cn))
	}
	return float64(m) / (2 * float64(cr))
}

// solve — коэффициенты двойственной формы по песням train.
func solve(K [][]float64, samples []Sample, train []int, lambda float64) ([]float64, bool) {
	var cn, cr int
	for _, i := range train {
		if samples[i].Neg {
			cn++
		} else {
			cr++
		}
	}
	if cn == 0 || cr == 0 {
		return nil, false
	}
	m := len(train)
	A := make([][]float64, m)
	y := make([]float64, m)
	for a, i := range train {
		A[a] = make([]float64, m)
		for b, j := range train {
			A[a][b] = K[i][j]
		}
		w := classWeight(m, cn, cr, samples[i].Neg)
		y[a] = -1
		if samples[i].Neg {
			y[a] = 1
		}
		A[a][a] += lambda / w
	}
	return cholSolve(A, y)
}

// CrossValidate — для каждой λ счёт всех песен «вслепую» (пять частей по группам-папкам) и две точности.
// Порядок Fit.OOF — как у samples.
func CrossValidate(samples []Sample, lambdas []float64) ([]Fit, error) {
	p, err := prepare(samples)
	if err != nil {
		return nil, err
	}
	n := len(samples)
	K := kernel(p.z, p.d)

	groupFold := map[string]int{}
	var gs []string
	for _, s := range samples {
		if _, ok := groupFold[s.Group]; !ok {
			groupFold[s.Group] = 0
			gs = append(gs, s.Group)
		}
	}
	sort.Slice(gs, func(i, j int) bool {
		hi, hj := hashOf(gs[i]), hashOf(gs[j])
		if hi != hj {
			return hi < hj
		}
		return gs[i] < gs[j]
	})
	for i, g := range gs {
		groupFold[g] = i % folds
	}

	var out []Fit
	for _, lambda := range lambdas {
		oof := make([]float64, n)
		for f := 0; f < folds; f++ {
			var train, test []int
			for i, s := range samples {
				if groupFold[s.Group] == f {
					test = append(test, i)
				} else {
					train = append(train, i)
				}
			}
			alpha, ok := solve(K, samples, train, lambda)
			if !ok {
				continue
			}
			for _, i := range test {
				var s float64
				for a, j := range train {
					s += K[i][j] * alpha[a]
				}
				oof[i] = s
			}
		}
		out = append(out, splitAUC(samples, oof, lambda))
	}
	return out, nil
}

func splitAUC(samples []Sample, oof []float64, lambda float64) Fit {
	var neg, pos, kept []float64
	for i, s := range samples {
		switch {
		case s.Neg:
			neg = append(neg, oof[i])
		case s.Pos:
			pos = append(pos, oof[i])
		default:
			kept = append(kept, oof[i])
		}
	}
	f := Fit{Lambda: lambda, OOF: oof, AUCPos: math.NaN(), AUCKept: math.NaN()}
	if len(neg) > 0 && len(pos) >= minPosForAUC {
		f.AUCPos = AUC(neg, pos)
	}
	if len(neg) > 0 && len(kept) > 0 {
		f.AUCKept = AUC(neg, kept)
	}
	return f
}

// Evaluate — еженедельная проверка: лучшая λ, точность, порог и решение «включать или нет».
func Evaluate(samples []Sample) (Report, []Fit, error) {
	var rep Report
	for _, s := range samples {
		switch {
		case s.Neg:
			rep.Neg++
		case s.Pos:
			rep.Pos++
		default:
			rep.Kept++
		}
	}
	rep.AUCPos, rep.AUCKept = math.NaN(), math.NaN()
	if rep.Neg < MinNeg || rep.Pos+rep.Kept < MinRef {
		rep.Reason = fmt.Sprintf("мало примеров: «не нравится» %d из нужных %d, «нравится» и обычных %d из нужных %d",
			rep.Neg, MinNeg, rep.Pos+rep.Kept, MinRef)
		return rep, nil, nil
	}
	fits, err := CrossValidate(samples, Lambdas)
	if err != nil {
		return rep, nil, err
	}
	best := 0
	for i, f := range fits {
		if f.MinAUCOf() > fits[best].MinAUCOf() {
			best = i
		}
	}
	b := fits[best]
	rep.Lambda, rep.AUCPos, rep.AUCKept = b.Lambda, b.AUCPos, b.AUCKept

	var ref, neg []float64
	for i, s := range samples {
		if s.Neg {
			neg = append(neg, b.OOF[i])
		} else {
			ref = append(ref, b.OOF[i])
		}
	}
	rep.Threshold = Quantile(ref, 1-FalseReject)
	rep.Catch = shareAbove(neg, rep.Threshold)
	switch {
	case b.MinAUCOf() < MinAUC:
		rep.Reason = fmt.Sprintf("звук пока не отличает «не нравится»: точность %.0f %% при нужных %.0f %%", 100*b.MinAUCOf(), 100*MinAUC)
	case rep.Catch < MinCatch:
		rep.Reason = fmt.Sprintf("фильтр ловил бы только %.0f %% из «не нравится» при нужных хотя бы %.0f %%", 100*rep.Catch, 100*MinCatch)
	default:
		rep.Enabled = true
	}
	return rep, fits, nil
}

// Model — обученный разделитель для оценки новых песен (весит ≈ 3·d чисел).
type Model struct {
	Lambda    float64   `json:"lambda"`
	Threshold float64   `json:"threshold"`
	Mean      []float32 `json:"mean"`
	Std       []float32 `json:"std"`
	W         []float32 `json:"w"`
}

// Train — обучить модель на всех песнях. Порог Threshold ставит вызывающий (из Report).
func Train(samples []Sample, lambda float64) (Model, error) {
	p, err := prepare(samples)
	if err != nil {
		return Model{}, err
	}
	K := kernel(p.z, p.d)
	all := make([]int, len(samples))
	for i := range all {
		all[i] = i
	}
	alpha, ok := solve(K, samples, all, lambda)
	if !ok {
		return Model{}, errors.New("модель не обучилась: нужны песни обоих классов")
	}
	m := Model{Lambda: lambda, Mean: make([]float32, p.d), Std: make([]float32, p.d), W: make([]float32, p.d)}
	for t := 0; t < p.d; t++ {
		var w float64
		for i := range samples {
			w += alpha[i] * p.z[i][t]
		}
		m.W[t] = float32(w / float64(p.d))
		m.Mean[t] = float32(p.mean[t])
		m.Std[t] = float32(p.std[t])
	}
	return m, nil
}

// Score — счёт песни: чем выше, тем больше она похожа на «не нравится». Порог — Model.Threshold.
func (m Model) Score(vec []float32) float64 {
	if len(vec) != len(m.W) {
		return math.Inf(-1) // отпечаток другой длины — оценивать нечем, не отсеиваем
	}
	v := l2(vec)
	var s float64
	for t, x := range v {
		s += float64(m.W[t]) * (x - float64(m.Mean[t])) / float64(m.Std[t])
	}
	return s
}

// Reject — отсеять ли песню.
func (m Model) Reject(vec []float32) bool { return m.Score(vec) >= m.Threshold }

// AUC — вероятность, что счёт случайной песни из a выше счёта случайной из b (0,5 — монетка, 1 — идеал).
func AUC(a, b []float64) float64 {
	if len(a) == 0 || len(b) == 0 {
		return math.NaN()
	}
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

// Quantile — значение, ниже которого лежит доля q счётов.
func Quantile(xs []float64, q float64) float64 {
	if len(xs) == 0 {
		return math.Inf(1)
	}
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

// shareAbove — доля счётов выше порога (0…1).
func shareAbove(xs []float64, th float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	n := 0
	for _, x := range xs {
		if x > th {
			n++
		}
	}
	return float64(n) / float64(len(xs))
}

func hashOf(s string) uint32 {
	h := fnv.New32a()
	_, _ = h.Write([]byte(s))
	return h.Sum32()
}

// cholSolve — решить A·x = b для симметричной положительно определённой A (A портится: раскладывается на месте).
func cholSolve(A [][]float64, b []float64) ([]float64, bool) {
	n := len(A)
	for i := 0; i < n; i++ {
		for j := 0; j <= i; j++ {
			sum := A[i][j]
			for k := 0; k < j; k++ {
				sum -= A[i][k] * A[j][k]
			}
			if i == j {
				if sum <= 0 {
					return nil, false
				}
				A[i][i] = math.Sqrt(sum)
			} else {
				A[i][j] = sum / A[j][j]
			}
		}
	}
	y := make([]float64, n)
	for i := 0; i < n; i++ {
		sum := b[i]
		for k := 0; k < i; k++ {
			sum -= A[i][k] * y[k]
		}
		y[i] = sum / A[i][i]
	}
	x := make([]float64, n)
	for i := n - 1; i >= 0; i-- {
		sum := y[i]
		for k := i + 1; k < n; k++ {
			sum -= A[k][i] * x[k]
		}
		x[i] = sum / A[i][i]
	}
	return x, true
}
