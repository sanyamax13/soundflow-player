package localdb

import (
	"math"
	"math/rand"
)

// Компактный k-means на L2-нормированных векторах: косинусная близость =
// скалярное произведение. Для «центров вкуса» (TASTE-PLAN §3). Без внешних
// пакетов, детерминированный сид — пересчёт воспроизводим.

// l2norm — L2-нормированная копия вектора. Нулевой вектор — как есть.
func l2norm(v []float32) []float32 {
	var s float64
	for _, x := range v {
		s += float64(x) * float64(x)
	}
	out := make([]float32, len(v))
	if s == 0 {
		copy(out, v)
		return out
	}
	inv := float32(1 / math.Sqrt(s))
	for i, x := range v {
		out[i] = x * inv
	}
	return out
}

func dotF32(a, b []float32) float64 {
	var s float64
	for i := range a {
		s += float64(a[i]) * float64(b[i])
	}
	return s
}

// kmeansCosine — k-means++ инициализация на косинусной дистанции, затем
// обычные итерации Ллойда. vecs должны быть уже L2-нормированы. Возвращает
// нормированные центроиды и номер кластера для каждого входа.
func kmeansCosine(vecs [][]float32, k, iters int, seed int64) (centroids [][]float32, assign []int) {
	n := len(vecs)
	if n == 0 || k <= 0 {
		return nil, nil
	}
	if k > n {
		k = n
	}
	dim := len(vecs[0])
	rng := rand.New(rand.NewSource(seed))

	centroids = make([][]float32, 0, k)
	centroids = append(centroids, append([]float32(nil), vecs[rng.Intn(n)]...))
	d2 := make([]float64, n)
	for len(centroids) < k {
		var sum float64
		for i, v := range vecs {
			best := -1.0
			for _, c := range centroids {
				if s := dotF32(v, c); s > best {
					best = s
				}
			}
			dist := 1 - best
			if dist < 0 {
				dist = 0
			}
			d2[i] = dist * dist
			sum += d2[i]
		}
		if sum == 0 {
			break
		}
		r := rng.Float64() * sum
		pick := n - 1
		for i, d := range d2 {
			r -= d
			if r <= 0 {
				pick = i
				break
			}
		}
		centroids = append(centroids, append([]float32(nil), vecs[pick]...))
	}
	k = len(centroids)

	assign = make([]int, n)
	for i := range assign {
		assign[i] = -1
	}
	for it := 0; it < iters; it++ {
		changed := false
		for i, v := range vecs {
			best, bi := -2.0, 0
			for ci, c := range centroids {
				if s := dotF32(v, c); s > best {
					best, bi = s, ci
				}
			}
			if assign[i] != bi {
				assign[i] = bi
				changed = true
			}
		}
		sums := make([][]float64, k)
		cnts := make([]int, k)
		for ci := range sums {
			sums[ci] = make([]float64, dim)
		}
		for i, v := range vecs {
			ci := assign[i]
			cnts[ci]++
			for j, x := range v {
				sums[ci][j] += float64(x)
			}
		}
		for ci := range centroids {
			if cnts[ci] == 0 {
				centroids[ci] = append([]float32(nil), vecs[rng.Intn(n)]...)
				continue
			}
			nc := make([]float32, dim)
			for j := range nc {
				nc[j] = float32(sums[ci][j] / float64(cnts[ci]))
			}
			centroids[ci] = l2norm(nc)
		}
		if !changed {
			break
		}
	}
	return centroids, assign
}
