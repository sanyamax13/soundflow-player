package main

import (
	"fmt"
	"hash/fnv"
	"math"
	"sort"
)

// runRidge — линейный разделитель «не нравится» / «всё остальное» по звуку: гребневая регрессия в двойственной форме
// (ядро — скалярное произведение z-оценок отпечатка), оценка перекрёстной проверкой по группам-папкам: песни одной
// папки никогда не попадают одновременно в обучение и в проверку. Сравнение с сырым косинусом даёт понять, стоит ли
// вообще отсеивать кандидатов «Волны» по звуку.
func runRidge(neg, pos, kept []*item) {
	all := append(append(append([]*item{}, neg...), pos...), kept...)
	n := len(all)
	if n == 0 {
		return
	}
	d := len(all[0].vec)

	// z-оценка по каждой из d координат
	mean := make([]float64, d)
	for _, it := range all {
		for t, v := range it.vec {
			mean[t] += float64(v)
		}
	}
	for t := range mean {
		mean[t] /= float64(n)
	}
	std := make([]float64, d)
	for _, it := range all {
		for t, v := range it.vec {
			dv := float64(v) - mean[t]
			std[t] += dv * dv
		}
	}
	for t := range std {
		std[t] = math.Sqrt(std[t]/float64(n)) + 1e-9
	}
	X := make([][]float64, n)
	for i, it := range all {
		X[i] = make([]float64, d)
		for t, v := range it.vec {
			X[i][t] = (float64(v) - mean[t]) / std[t]
		}
	}
	K := make([][]float64, n)
	for i := range K {
		K[i] = make([]float64, n)
	}
	for i := 0; i < n; i++ {
		for j := i; j < n; j++ {
			var s float64
			for t := 0; t < d; t++ {
				s += X[i][t] * X[j][t]
			}
			s /= float64(d)
			K[i][j], K[j][i] = s, s
		}
	}

	// пять частей по группам-папкам (порядок групп — по хэшу, чтобы был воспроизводим)
	const folds = 5
	groupFold := map[string]int{}
	var gs []string
	for _, it := range all {
		if _, ok := groupFold[it.group]; !ok {
			groupFold[it.group] = 0
			gs = append(gs, it.group)
		}
	}
	sort.Slice(gs, func(i, j int) bool { return hashOf(gs[i]) < hashOf(gs[j]) })
	for i, g := range gs {
		groupFold[g] = i % folds
	}

	nNeg, nPos := len(neg), len(pos)
	for _, lambda := range []float64{0.3, 3, 30} {
		oof := make([]float64, n)
		for f := 0; f < folds; f++ {
			var train, test []int
			for i, it := range all {
				if groupFold[it.group] == f {
					test = append(test, i)
				} else {
					train = append(train, i)
				}
			}
			var cn, cr int
			for _, i := range train {
				if i < nNeg {
					cn++
				} else {
					cr++
				}
			}
			if cn == 0 || cr == 0 {
				continue
			}
			m := len(train)
			A := make([][]float64, m)
			y := make([]float64, m)
			for a, i := range train {
				A[a] = make([]float64, m)
				for b, j := range train {
					A[a][b] = K[i][j]
				}
				// классы уравновешены: каждый весит поровну
				w := float64(m) / (2 * float64(cr))
				y[a] = -1
				if i < nNeg {
					w = float64(m) / (2 * float64(cn))
					y[a] = 1
				}
				A[a][a] += lambda / w
			}
			alpha, ok := cholSolve(A, y)
			if !ok {
				fmt.Println("ридж: матрица не разложилась, пропускаю часть", f)
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
		report(fmt.Sprintf("линейный разделитель по звуку (ридж λ=%g, проверка по папкам)", lambda),
			oof[:nNeg], oof[nNeg:nNeg+nPos], oof[nNeg+nPos:])
	}
	_ = nPos
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
