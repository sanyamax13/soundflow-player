package db

import (
	"context"
	"testing"
	"time"
)

// mkVec — 2048-мерный вектор с заданными ненулевыми позициями.
func mkVec(set map[int]float32) []float32 {
	v := make([]float32, 2048)
	for i, f := range set {
		v[i] = f
	}
	return v
}

func TestOrderBySimilarity(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	tag := "sim-" + time.Now().Format("150405.000000")
	ids := map[string]string{"seed": "t_" + tag + "_s", "near": "t_" + tag + "_n", "far": "t_" + tag + "_f", "novec": "t_" + tag + "_x"}
	t.Cleanup(func() {
		for _, id := range ids {
			_, _ = p.p.Exec(ctx, `DELETE FROM tracks WHERE id = $1`, id)
		}
	})

	mk := func(id, name string) {
		nk := tag + "__" + name
		err := p.InsertTrackWithFile(ctx,
			NewTrack{ID: id, Artist: tag, Title: name, NormalizedKey: nk, ReleaseKind: "studio"},
			NewTrackFile{ID: id + "_f", NormalizedKey: nk, FilePath: `E:\x\` + id + `.mp3`, MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
		)
		if err != nil {
			t.Fatalf("insert %s: %v", name, err)
		}
	}
	mk(ids["seed"], "seed")
	mk(ids["near"], "near")
	mk(ids["far"], "far")
	mk(ids["novec"], "novec")

	must := func(id string, v []float32) {
		if err := p.SetFeatureVector(ctx, id, v); err != nil {
			t.Fatalf("SetFeatureVector %s: %v", id, err)
		}
	}
	must(ids["seed"], mkVec(map[int]float32{0: 1}))
	must(ids["near"], mkVec(map[int]float32{0: 1, 1: 0.05}))
	must(ids["far"], mkVec(map[int]float32{0: 0.2, 1: 1}))
	// novec — намеренно без вектора

	cands := []string{ids["far"], ids["novec"], ids["near"], ids["seed"]}
	got, err := p.OrderBySimilarity(ctx, ids["seed"], cands)
	if err != nil {
		t.Fatalf("OrderBySimilarity: %v", err)
	}

	want := []string{ids["near"], ids["far"], ids["novec"]}
	if len(got) != len(want) {
		t.Fatalf("длина: ждал %v, получил %v", want, got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("порядок: ждал %v, получил %v", want, got)
		}
	}
}

func TestOrderBySimilaritySeedWithoutVector(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	tag := "sim0-" + time.Now().Format("150405.000000")
	s, a, b := "t_"+tag+"_s", "t_"+tag+"_a", "t_"+tag+"_b"
	t.Cleanup(func() {
		for _, id := range []string{s, a, b} {
			_, _ = p.p.Exec(ctx, `DELETE FROM tracks WHERE id = $1`, id)
		}
	})
	for _, id := range []string{s, a, b} {
		nk := tag + "__" + id
		if err := p.InsertTrackWithFile(ctx,
			NewTrack{ID: id, Artist: tag, Title: id, NormalizedKey: nk, ReleaseKind: "studio"},
			NewTrackFile{ID: id + "_f", NormalizedKey: nk, FilePath: `E:\x\` + id + `.mp3`, MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
		); err != nil {
			t.Fatalf("insert %s: %v", id, err)
		}
	}

	// У seed вектора нет — очередь должна вернуться целой, в исходном порядке, без seed.
	got, err := p.OrderBySimilarity(ctx, s, []string{a, s, b})
	if err != nil {
		t.Fatalf("OrderBySimilarity: %v", err)
	}
	if len(got) != 2 || got[0] != a || got[1] != b {
		t.Fatalf("ждал [a b], получил %v", got)
	}
}
