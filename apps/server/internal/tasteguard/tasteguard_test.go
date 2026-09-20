package tasteguard

import (
	"fmt"
	"math"
	"math/rand"
	"testing"
)

const dim = 64

func gauss(rng *rand.Rand, center []float64, sigma float64) []float32 {
	v := make([]float32, dim)
	for t := range v {
		v[t] = float32(center[t] + sigma*rng.NormFloat64())
	}
	return v
}

func randCenter(rng *rand.Rand, scale float64) []float64 {
	c := make([]float64, dim)
	for t := range c {
		c[t] = scale * rng.NormFloat64()
	}
	return c
}

// centers — общие для набора «звуковые центры»: обычные песни вокруг base, «не нравится» сдвинуты на shift (0 — не отличаются).
func centers(seed int64, sep float64) (base, shift []float64) {
	rng := rand.New(rand.NewSource(seed))
	return randCenter(rng, 1), randCenter(rng, sep)
}

// makeSet — nNeg «не нравится», nPos «нравится», nKept обычных; sep — насколько центры «не нравится» и остальных
// разведены (0 — одно и то же распределение). Группы по 8 песен подряд.
func makeSet(seed int64, nNeg, nPos, nKept int, sep float64) []Sample {
	base, shift := centers(seed, sep)
	rng := rand.New(rand.NewSource(seed + 1000))
	var out []Sample
	add := func(n int, neg, pos bool, name string) {
		for i := 0; i < n; i++ {
			c := make([]float64, dim)
			for t := range c {
				c[t] = base[t]
				if neg {
					c[t] += shift[t]
				}
			}
			out = append(out, Sample{Vec: gauss(rng, c, 1), Group: fmt.Sprintf("%s-%d", name, i/8), Neg: neg, Pos: pos})
		}
	}
	add(nNeg, true, false, "neg")
	add(nPos, false, true, "pos")
	add(nKept, false, false, "kept")
	return out
}

// Звук действительно отличает «не нравится» — сторож включается, точность высокая, отсеивает много и мало ошибается;
// обученная модель на новых песнях ведёт себя так же.
func TestEvaluateEnablesWhenSeparable(t *testing.T) {
	samples := makeSet(1, 150, 40, 400, 0.6)
	rep, _, err := Evaluate(samples)
	if err != nil {
		t.Fatal(err)
	}
	if !rep.Enabled || rep.AUCKept < 0.9 || rep.AUCPos < 0.9 || rep.Catch < 0.4 {
		t.Fatalf("ждали включение с высокой точностью: %+v", rep)
	}
	model, err := Train(samples, rep.Lambda)
	if err != nil {
		t.Fatal(err)
	}
	model.Threshold = rep.Threshold

	// новые песни вокруг тех же центров, другим генератором шума
	base, shift := centers(1, 0.6)
	gen := rand.New(rand.NewSource(777))
	var hitNeg, hitRef, nNeg, nRef int
	for i := 0; i < 300; i++ {
		neg := i%2 == 0
		c := make([]float64, dim)
		for t := range c {
			c[t] = base[t]
			if neg {
				c[t] += shift[t]
			}
		}
		v := gauss(gen, c, 1)
		if neg {
			nNeg++
			if model.Reject(v) {
				hitNeg++
			}
		} else {
			nRef++
			if model.Reject(v) {
				hitRef++
			}
		}
	}
	if float64(hitNeg)/float64(nNeg) < 0.4 {
		t.Errorf("новых «не нравится» отсеяно %d из %d — слишком мало", hitNeg, nNeg)
	}
	if float64(hitRef)/float64(nRef) > 0.10 {
		t.Errorf("новых обычных отсеяно по ошибке %d из %d — слишком много", hitRef, nRef)
	}
}

// Звук ничего не отличает (одно и то же распределение) — сторож НЕ включается и говорит почему.
func TestEvaluateStaysOffWhenIndistinguishable(t *testing.T) {
	samples := makeSet(2, 150, 40, 400, 0)
	rep, _, err := Evaluate(samples)
	if err != nil {
		t.Fatal(err)
	}
	if rep.Enabled || rep.Reason == "" {
		t.Fatalf("ждали «не включено» с причиной: %+v", rep)
	}
	if math.Abs(rep.AUCKept-0.5) > 0.12 {
		t.Errorf("при одинаковых распределениях точность должна быть около 0,5, а она %.2f", rep.AUCKept)
	}
}

// Мало примеров — не строим и не пугаем цифрами, причина называет, чего не хватает.
func TestEvaluateNeedsEnoughExamples(t *testing.T) {
	samples := makeSet(3, 20, 5, 100, 0.6)
	rep, fits, err := Evaluate(samples)
	if err != nil {
		t.Fatal(err)
	}
	if rep.Enabled || fits != nil || rep.Reason == "" {
		t.Fatalf("ждали «мало примеров»: %+v", rep)
	}
}

// Проверка по группам не даёт себя обмануть: в каждой группе песни почти одинаковы, а «не нравится» назначено группам
// случайно. Без разделения по группам точность была бы почти идеальной, с разделением — около 0,5.
func TestCrossValidateDoesNotLeakThroughGroups(t *testing.T) {
	rng := rand.New(rand.NewSource(4))
	var samples []Sample
	for g := 0; g < 60; g++ {
		center := randCenter(rng, 1)
		neg := g%3 == 0
		for i := 0; i < 8; i++ {
			samples = append(samples, Sample{Vec: gauss(rng, center, 0.05), Group: fmt.Sprintf("g%d", g), Neg: neg})
		}
	}
	fits, err := CrossValidate(samples, []float64{3})
	if err != nil {
		t.Fatal(err)
	}
	if a := fits[0].AUCKept; a > 0.7 {
		t.Fatalf("точность %.2f слишком высока для случайных меток: проверка «подглядывает» внутри папок", a)
	}
}

func TestScoreWrongLengthNeverRejects(t *testing.T) {
	m := Model{Threshold: 0, Mean: make([]float32, 4), Std: []float32{1, 1, 1, 1}, W: []float32{1, 1, 1, 1}}
	if m.Reject([]float32{1, 2}) {
		t.Fatal("отпечаток чужой длины отсеиваться не должен")
	}
}

func TestAUCAndQuantile(t *testing.T) {
	if a := AUC([]float64{3, 4}, []float64{1, 2}); a != 1 {
		t.Errorf("AUC идеального разделения = %v", a)
	}
	if a := AUC([]float64{1, 1}, []float64{1, 1}); a != 0.5 {
		t.Errorf("AUC равных = %v", a)
	}
	if q := Quantile([]float64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, 0.9); q != 9 {
		t.Errorf("квантиль 0,9 = %v", q)
	}
}
