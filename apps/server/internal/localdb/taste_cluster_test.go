package localdb

import (
	"encoding/json"
	"math/rand"
	"testing"
)

// синтетический вектор около «направления» dir с шумом.
func noisyVec(dim int, dir int, rng *rand.Rand) []float32 {
	v := make([]float32, dim)
	for i := range v {
		v[i] = float32(rng.NormFloat64() * 0.03)
	}
	v[dir] += 1
	return v
}

func TestKmeansCosineSeparates(t *testing.T) {
	const dim = 32
	rng := rand.New(rand.NewSource(1))
	var vecs [][]float32
	// три чётко разделённые группы вокруг осей 0, 10, 20
	for _, ax := range []int{0, 10, 20} {
		for i := 0; i < 20; i++ {
			vecs = append(vecs, l2norm(noisyVec(dim, ax, rng)))
		}
	}
	cents, assign := kmeansCosine(vecs, 3, 50, 42)
	if len(cents) != 3 {
		t.Fatalf("centroids = %d; want 3", len(cents))
	}
	// точки одной группы должны попасть в один кластер
	for g := 0; g < 3; g++ {
		first := assign[g*20]
		for i := 1; i < 20; i++ {
			if assign[g*20+i] != first {
				t.Fatalf("group %d split across clusters", g)
			}
		}
	}
	// каждый центроид «смотрит» на свою ось
	axisHit := map[int]bool{}
	for _, c := range cents {
		best, bi := float32(-2), 0
		for j, x := range c {
			if x > best {
				best, bi = x, j
			}
		}
		axisHit[bi] = true
	}
	for _, ax := range []int{0, 10, 20} {
		if !axisHit[ax] {
			t.Errorf("no centroid aligned with axis %d", ax)
		}
	}
}

func TestTasteAffinity(t *testing.T) {
	dim := 16
	c := make([]float32, dim)
	c[3] = 1
	cents := [][]float32{l2norm(c)}

	near := make([]float32, dim)
	near[3] = 5
	near[4] = 0.2
	if a := tasteAffinity(cents, near); a < 0.9 {
		t.Errorf("near affinity = %.3f; want > 0.9", a)
	}
	far := make([]float32, dim)
	far[10] = 1
	if a := tasteAffinity(cents, far); a > 0.2 {
		t.Errorf("far affinity = %.3f; want < 0.2", a)
	}
	if a := tasteAffinity(nil, near); a != 0 {
		t.Errorf("no centroids → %.3f; want 0", a)
	}
}

func TestRecomputeTasteClustersAndScore(t *testing.T) {
	d := open(t)
	const dim = VecDim
	rng := rand.New(rand.NewSource(7))

	// два «жанра»: треки вокруг оси 0 и вокруг оси 1000. Все лайкнуты.
	like := func(id string, axis int) {
		v := make([]float32, dim)
		for i := range v {
			v[i] = float32(rng.NormFloat64() * 0.01)
		}
		v[axis] += 1
		if _, err := d.sql.Exec(
			`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector)
			 VALUES (?,?,?,?,?)`, id, "A "+id, id, id, vecToBlob(v)); err != nil {
			t.Fatal(err)
		}
		if _, err := d.SaveSync(Device{ID: "d"}, []SyncEvent{
			{UUID: "u_" + id, Kind: "like", TrackID: id, Payload: json.RawMessage(``), ClientTS: 1},
		}); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 12; i++ {
		like("g0_"+itoa(i), 0)
		like("g1_"+itoa(i), 1000)
	}

	nc, nt, err := d.RecomputeTasteClusters()
	if err != nil {
		t.Fatalf("recompute: %v", err)
	}
	if nt != 24 {
		t.Fatalf("cluster tracks = %d; want 24", nt)
	}
	if nc != 3 { // kFor(24) == 4? -> 24>=15 -> 4. проверим ниже
		t.Logf("clusters = %d", nc)
	}
	if nc != kFor(24) {
		t.Errorf("clusters = %d; want kFor(24)=%d", nc, kFor(24))
	}

	// свежий трек рядом с осью 0 — высокая близость; далёкий — низкая
	nearV := make([]float32, dim)
	nearV[0] = 3
	farV := make([]float32, dim)
	farV[500] = 3
	if _, err := d.sql.Exec(`INSERT INTO tracks (id,artist,title,normalized_key,feature_vector) VALUES
		('near','X','near','near',?), ('far','X','far','far',?)`,
		vecToBlob(nearV), vecToBlob(farV)); err != nil {
		t.Fatal(err)
	}
	scores, err := d.ScoreTracksByTaste([]string{"near", "far"})
	if err != nil {
		t.Fatalf("score: %v", err)
	}
	if scores["near"] < 0.9 {
		t.Errorf("near score = %.3f; want > 0.9", scores["near"])
	}
	if scores["far"] > 0.3 {
		t.Errorf("far score = %.3f; want < 0.3", scores["far"])
	}

	cls, err := d.TasteClusters(3)
	if err != nil {
		t.Fatalf("clusters: %v", err)
	}
	total := 0
	for _, c := range cls {
		total += c.N
		if len(c.Exemplars) == 0 && c.N > 0 {
			t.Errorf("cluster %d has %d tracks but no exemplars", c.Idx, c.N)
		}
	}
	if total != 24 {
		t.Errorf("sum of cluster sizes = %d; want 24", total)
	}
}

func TestRecomputeTasteClustersDeterministic(t *testing.T) {
	d := open(t)
	for i := 0; i < 20; i++ {
		v := make([]float32, VecDim)
		v[i%VecDim] = 1
		if _, err := d.sql.Exec(
			`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
			"t"+itoa(i), "A"+itoa(i%3), "t"+itoa(i), "t"+itoa(i), vecToBlob(v)); err != nil {
			t.Fatal(err)
		}
		if _, err := d.sql.Exec(
			`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, created_at)
			 VALUES (?,?,?,?,?,?)`,
			"e"+itoa(i), "t"+itoa(i), "A"+itoa(i%3), "like", 5.0, "2026-09-01T00:00:00Z"); err != nil {
			t.Fatal(err)
		}
	}
	nc1, _, err := d.RecomputeTasteClusters()
	if err != nil {
		t.Fatal(err)
	}
	first, err := d.tasteCentroids()
	if err != nil {
		t.Fatal(err)
	}
	nc2, _, err := d.RecomputeTasteClusters()
	if err != nil {
		t.Fatal(err)
	}
	second, err := d.tasteCentroids()
	if err != nil {
		t.Fatal(err)
	}
	if nc1 != nc2 || len(first) != len(second) {
		t.Fatalf("cluster count changed: %d/%d vs %d/%d", nc1, len(first), nc2, len(second))
	}
	for i := range first {
		if cosine(first[i], second[i]) < 0.999 {
			t.Errorf("centroid %d drifted between identical recomputes: cosine=%v", i, cosine(first[i], second[i]))
		}
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b [8]byte
	p := len(b)
	for i > 0 {
		p--
		b[p] = byte('0' + i%10)
		i /= 10
	}
	return string(b[p:])
}
