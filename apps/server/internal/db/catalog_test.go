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

func TestCatalogHidesBlockedFlagsFavorite(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	tag := "lm-" + time.Now().Format("150405.000000")
	fav := "t_" + tag + "_fav"
	blk := "t_" + tag + "_blk"
	plain := "t_" + tag + "_pln"
	kFav := tag + "__fav"
	kBlk := tag + "__blk"
	kPln := tag + "__pln"
	t.Cleanup(func() {
		for _, id := range []string{fav, blk, plain} {
			_, _ = p.p.Exec(ctx, `DELETE FROM tracks WHERE id=$1`, id)
		}
		for _, k := range []string{kFav, kBlk} {
			_, _ = p.p.Exec(ctx, `DELETE FROM legacy_marks WHERE normalized_key=$1`, k)
		}
	})

	mk := func(id, nk string) {
		if err := p.InsertTrackWithFile(ctx,
			NewTrack{ID: id, Artist: tag, Title: id, NormalizedKey: nk, ReleaseKind: "studio"},
			NewTrackFile{ID: id + "_f", NormalizedKey: nk, FilePath: `E:\x\` + id + `.mp3`, MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
		); err != nil {
			t.Fatalf("insert %s: %v", id, err)
		}
	}
	mk(fav, kFav)
	mk(blk, kBlk)
	mk(plain, kPln)

	if _, err := p.LegacyMarksInsert(ctx, map[string]LegacyMark{
		kFav: {Key: kFav, Kind: "favorite"},
		kBlk: {Key: kBlk, Kind: "blocked"},
	}); err != nil {
		t.Fatalf("marks: %v", err)
	}

	list, err := p.CatalogSearch(ctx, tag, 50)
	if err != nil {
		t.Fatalf("CatalogSearch: %v", err)
	}
	seen := map[string]bool{}
	favFlag := map[string]bool{}
	for _, tr := range list {
		seen[tr.ID] = true
		favFlag[tr.ID] = tr.Favorite
	}
	if seen[blk] {
		t.Error("заблокированный трек не должен быть в выдаче каталога")
	}
	if !seen[fav] || !seen[plain] {
		t.Fatalf("ждал fav и plain в выдаче, получил %v", seen)
	}
	if !favFlag[fav] {
		t.Error("favorite=true не проставлен для трека из старого избранного")
	}
	if favFlag[plain] {
		t.Error("favorite у обычного трека должен быть false")
	}
}

func TestNextLibraryBatch(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	tag := "nb-" + time.Now().Format("150405.000000")
	fav := "t_" + tag + "_fav"
	a := "t_" + tag + "_a"
	b := "t_" + tag + "_b"
	blocked := "t_" + tag + "_blk"
	kFav, kA, kB, kBlk := tag+"__fav", tag+"__a", tag+"__b", tag+"__blk"
	t.Cleanup(func() {
		for _, id := range []string{fav, a, b, blocked} {
			_, _ = p.p.Exec(ctx, `DELETE FROM tracks WHERE id=$1`, id)
		}
		for _, k := range []string{kFav, kBlk} {
			_, _ = p.p.Exec(ctx, `DELETE FROM legacy_marks WHERE normalized_key=$1`, k)
		}
	})

	mk := func(id, nk string, size int64) {
		if err := p.InsertTrackWithFile(ctx,
			NewTrack{ID: id, Artist: tag, Title: id, NormalizedKey: nk, ReleaseKind: "studio"},
			NewTrackFile{ID: id + "_f", NormalizedKey: nk, FilePath: `E:\x\` + id + `.mp3`, MimeType: "audio/mpeg", SizeBytes: size, Source: "test", QualityTier: "excellent"},
		); err != nil {
			t.Fatalf("insert %s: %v", id, err)
		}
	}
	mk(fav, kFav, 1000)
	mk(a, kA, 1000)
	mk(b, kB, 1000)
	mk(blocked, kBlk, 1000)

	if _, err := p.LegacyMarksInsert(ctx, map[string]LegacyMark{
		kFav: {Key: kFav, Kind: "favorite"},
		kBlk: {Key: kBlk, Kind: "blocked"},
	}); err != nil {
		t.Fatalf("marks: %v", err)
	}

	// Бюджет в 1500 байт — должен взять fav (избранное вперёд) и остановиться,
	// как только накопленное >= бюджета (после первого же трека: 1000 < 1500,
	// возьмёт второй, тогда 2000 >= 1500 и хватит).
	list, total, err := p.NextLibraryBatch(ctx, nil, 1500)
	if err != nil {
		t.Fatalf("NextLibraryBatch: %v", err)
	}
	names := map[string]bool{}
	for _, t2 := range list {
		names[t2.ID] = true
	}
	if !names[fav] {
		t.Errorf("избранное должно быть первым и попасть в порцию: %+v", list)
	}
	if names[blocked] {
		t.Error("заблокированный трек не должен попасть в порцию")
	}
	if len(list) < 1 || total < 1000 {
		t.Errorf("неверный результат: len=%d total=%d", len(list), total)
	}
	if list[0].ID != fav {
		t.Errorf("ждал избранное первым, получил %+v", list[0])
	}

	// exclude — favorite уже скачан, дальше идут a/b в порядке добавления.
	list2, _, err := p.NextLibraryBatch(ctx, []string{fav, blocked}, 500)
	if err != nil {
		t.Fatalf("NextLibraryBatch#2: %v", err)
	}
	if len(list2) == 0 || (list2[0].ID != a && list2[0].ID != b) {
		t.Fatalf("ждал a или b первым после исключения избранного, получил %+v", list2)
	}
	for _, tr := range list2 {
		if tr.ID == fav || tr.ID == blocked {
			t.Errorf("исключённый или заблокированный трек попал в порцию: %s", tr.ID)
		}
	}
}

func TestTrashedTracks(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	tag := "trash-" + time.Now().Format("150405.000000")
	blocked := "t_" + tag + "_blk"
	plain := "t_" + tag + "_pln"
	kBlk := tag + "__blk"
	kPln := tag + "__pln"
	// Старая метка из чёрного списка старого плеера БЕЗ своего трека в
	// каталоге — не должна попасть в «Корзину» (вернуть-то нечего).
	kOldOnly := tag + "__old_only"
	t.Cleanup(func() {
		for _, id := range []string{blocked, plain} {
			_, _ = p.p.Exec(ctx, `DELETE FROM tracks WHERE id=$1`, id)
		}
		for _, k := range []string{kBlk, kOldOnly} {
			_, _ = p.p.Exec(ctx, `DELETE FROM legacy_marks WHERE normalized_key=$1`, k)
		}
	})

	mk := func(id, nk string) {
		if err := p.InsertTrackWithFile(ctx,
			NewTrack{ID: id, Artist: tag, Title: id, NormalizedKey: nk, ReleaseKind: "studio"},
			NewTrackFile{ID: id + "_f", NormalizedKey: nk, FilePath: `E:\x\` + id + `.mp3`, MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
		); err != nil {
			t.Fatalf("insert %s: %v", id, err)
		}
	}
	mk(blocked, kBlk)
	mk(plain, kPln)

	if _, err := p.LegacyMarksInsert(ctx, map[string]LegacyMark{
		kBlk:     {Key: kBlk, Kind: "blocked"},
		kOldOnly: {Key: kOldOnly, Kind: "blocked"}, // без трека — «мёртвая» метка
	}); err != nil {
		t.Fatalf("marks: %v", err)
	}

	list, err := p.TrashedTracks(ctx)
	if err != nil {
		t.Fatalf("TrashedTracks: %v", err)
	}
	seen := map[string]bool{}
	for _, r := range list {
		seen[r.TrackID] = true
	}
	if !seen[blocked] {
		t.Errorf("заблокированный трек с файлом должен быть в Корзине: %+v", list)
	}
	if seen[plain] {
		t.Error("обычный (не blocked) трек не должен быть в Корзине")
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

func TestTracksMissingCoverURL(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	tag := "cov-" + time.Now().Format("150405.000000")
	withCover := "t_" + tag + "_has"
	noCover := "t_" + tag + "_none"
	t.Cleanup(func() {
		for _, id := range []string{withCover, noCover} {
			_, _ = p.p.Exec(ctx, `DELETE FROM tracks WHERE id=$1`, id)
		}
	})
	mk := func(id, cover string) {
		nk := tag + "__" + id
		if err := p.InsertTrackWithFile(ctx,
			NewTrack{ID: id, Artist: tag, Title: id, NormalizedKey: nk, ReleaseKind: "studio", CoverURL: cover},
			NewTrackFile{ID: id + "_f", NormalizedKey: nk, FilePath: `E:\x\` + id + `.mp3`, MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
		); err != nil {
			t.Fatalf("insert %s: %v", id, err)
		}
	}
	mk(withCover, "https://already-known")
	mk(noCover, "")

	list, err := p.TracksMissingCoverURL(ctx, 10000)
	if err != nil {
		t.Fatalf("TracksMissingCoverURL: %v", err)
	}
	seen := map[string]bool{}
	for _, c := range list {
		seen[c.ID] = true
	}
	if !seen[noCover] {
		t.Errorf("трек без cover_url должен быть кандидатом: %+v", list)
	}
	if seen[withCover] {
		t.Error("трек с уже известным cover_url не должен быть кандидатом")
	}
}

func TestTrackArtistTitle(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	tag := "artitle-" + time.Now().Format("150405.000000")
	id := "t_" + tag
	t.Cleanup(func() { _, _ = p.p.Exec(ctx, `DELETE FROM tracks WHERE id=$1`, id) })
	if err := p.InsertTrackWithFile(ctx,
		NewTrack{ID: id, Artist: "Кто-то", Title: "Песня", NormalizedKey: tag, ReleaseKind: "studio"},
		NewTrackFile{ID: id + "_f", NormalizedKey: tag, FilePath: `E:\x\` + id + `.mp3`, MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
	); err != nil {
		t.Fatalf("insert: %v", err)
	}

	artist, title, ok, err := p.TrackArtistTitle(ctx, id)
	if err != nil || !ok || artist != "Кто-то" || title != "Песня" {
		t.Fatalf("ждал (Кто-то, Песня, true), получил (%q, %q, %v), err=%v", artist, title, ok, err)
	}

	_, _, ok, err = p.TrackArtistTitle(ctx, "t_нет-такого")
	if err != nil || ok {
		t.Fatalf("несуществующий id: ждал ok=false, получил ok=%v err=%v", ok, err)
	}
}

func TestDeleteTrackFreesNormalizedKey(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	tag := "deltrack-" + time.Now().Format("150405.000000")
	id := "t_" + tag
	t.Cleanup(func() { _, _ = p.p.Exec(ctx, `DELETE FROM tracks WHERE id=$1`, id) })
	if err := p.InsertTrackWithFile(ctx,
		NewTrack{ID: id, Artist: "A", Title: "B", NormalizedKey: tag, ReleaseKind: "studio"},
		NewTrackFile{ID: id + "_f", NormalizedKey: tag, FilePath: `E:\x\` + id + `.mp3`, MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
	); err != nil {
		t.Fatalf("insert: %v", err)
	}

	if err := p.DeleteTrack(ctx, id); err != nil {
		t.Fatalf("DeleteTrack: %v", err)
	}

	got, err := p.TrackByKey(ctx, tag)
	if err != nil {
		t.Fatalf("TrackByKey: %v", err)
	}
	if got != nil {
		t.Fatalf("normalized_key должен освободиться, а трек нашёлся: %+v", got)
	}

	var n int
	if err := p.p.QueryRow(ctx, `SELECT count(*) FROM track_files WHERE track_id=$1`, id).Scan(&n); err != nil {
		t.Fatalf("check track_files: %v", err)
	}
	if n != 0 {
		t.Errorf("track_files должны были уйти каскадом, осталось %d", n)
	}
}

func TestSetCoverURLAndTrackCoverURL(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	tag := "cov2-" + time.Now().Format("150405.000000")
	id := "t_" + tag
	nk := tag + "__x"
	t.Cleanup(func() { _, _ = p.p.Exec(ctx, `DELETE FROM tracks WHERE id=$1`, id) })
	if err := p.InsertTrackWithFile(ctx,
		NewTrack{ID: id, Artist: tag, Title: id, NormalizedKey: nk, ReleaseKind: "studio"},
		NewTrackFile{ID: id + "_f", NormalizedKey: nk, FilePath: `E:\x\` + id + `.mp3`, MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
	); err != nil {
		t.Fatalf("insert: %v", err)
	}

	if url, found, err := p.TrackCoverURL(ctx, id); err != nil || found || url != "" {
		t.Fatalf("свежий трек без обложки: url=%q found=%v err=%v", url, found, err)
	}

	if err := p.SetCoverURL(ctx, id, "https://cover.example/x.jpg"); err != nil {
		t.Fatalf("SetCoverURL: %v", err)
	}
	if url, found, err := p.TrackCoverURL(ctx, id); err != nil || !found || url != "https://cover.example/x.jpg" {
		t.Fatalf("после SetCoverURL: url=%q found=%v err=%v", url, found, err)
	}
}
