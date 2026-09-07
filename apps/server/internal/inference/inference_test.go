package inference

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// Сверка Go (ffmpeg + onnxruntime) с эталоном PyTorch из шага 0.
// Пропускается, если нет ассетов или тест-набора (CI без onnxruntime.dll).
func TestEmbedMatchesPyTorchReference(t *testing.T) {
	lab := os.Getenv("SOUNDFLOW_LAB")
	if lab == "" {
		lab = `E:\soundflow-lab`
	}
	valDir := filepath.Join(lab, "cnn14-onnx-validation")
	refPath := filepath.Join(valDir, "ref_embeddings.json")
	assets := filepath.Join(lab, "assets")

	if _, err := os.Stat(refPath); err != nil {
		t.Skip("нет ref_embeddings.json — пропуск")
	}
	if _, err := os.Stat(filepath.Join(assets, "cnn14.onnx")); err != nil {
		t.Skip("нет assets/cnn14.onnx — пропуск")
	}

	raw, err := os.ReadFile(refPath)
	if err != nil {
		t.Fatal(err)
	}
	var ref map[string][]float32
	if err := json.Unmarshal(raw, &ref); err != nil {
		t.Fatal(err)
	}

	eng, err := Open(assets)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer eng.Close()

	names := make([]string, 0, len(ref))
	for k := range ref {
		names = append(names, k)
	}
	sort.Strings(names)

	goEmb := make(map[string][]float32, len(names))
	var minCos, sumCos float64 = 2, 0
	for _, name := range names {
		want := ref[name]
		got, err := eng.EmbedFile(filepath.Join(valDir, "audio", name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if len(got) != len(want) {
			t.Fatalf("%s: длина %d != %d", name, len(got), len(want))
		}
		goEmb[name] = got
		c := cos32(got, want)
		if c < minCos {
			minCos = c
		}
		sumCos += c
		// Порог мягкий: Go-декод (ffmpeg) отличается от librosa+minimp3 —
		// в основном срез гэплесс-задержки mp3. Раз пересчитываем ВСЮ базу
		// одним путём, важна не абсолютная близость к старым векторам,
		// а совпадение списков «похожих» (см. ниже).
		if c < 0.99 {
			t.Errorf("%s: cos=%.5f < 0.99 — слишком большое расхождение декода", name, c)
		}
	}
	t.Logf("raw cos Go↔PyTorch: min %.6f, среднее %.6f (разница = путь декода)", minCos, sumCos/float64(len(names)))

	// Главная проверка: топ-8 ближайших у каждого трека — совпадают ли списки,
	// посчитанные по старым (PyTorch) и новым (Go) векторам.
	const k = 8
	totOverlap, worst := 0, k
	for _, a := range names {
		pyRank := rankByCos(a, names, func(x string) []float32 { return ref[x] })
		goRank := rankByCos(a, names, func(x string) []float32 { return goEmb[x] })
		ov := overlap(pyRank[:k], goRank[:k])
		totOverlap += ov
		if ov < worst {
			worst = ov
		}
	}
	avg := float64(totOverlap) / float64(len(names))
	t.Logf("совпадение топ-%d соседей PyTorch↔Go: среднее %.2f/%d, худшее %d/%d", k, avg, k, worst, k)
	if avg < float64(k)-1.5 { // в среднем не больше ~1.5 позиций расходится
		t.Errorf("списки «похожих» разошлись сильнее допустимого: среднее %.2f/%d", avg, k)
	}
}

func rankByCos(seed string, all []string, vec func(string) []float32) []string {
	sv := vec(seed)
	type sc struct {
		id string
		c  float64
	}
	arr := make([]sc, 0, len(all)-1)
	for _, id := range all {
		if id == seed {
			continue
		}
		arr = append(arr, sc{id, cos32(sv, vec(id))})
	}
	sort.Slice(arr, func(i, j int) bool { return arr[i].c > arr[j].c })
	out := make([]string, len(arr))
	for i, s := range arr {
		out[i] = s.id
	}
	return out
}

func overlap(a, b []string) int {
	m := make(map[string]bool, len(a))
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

func cos32(a, b []float32) float64 {
	var dot, na, nb float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
		na += float64(a[i]) * float64(a[i])
		nb += float64(b[i]) * float64(b[i])
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return dot / (math.Sqrt(na) * math.Sqrt(nb))
}
