package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"soundflow/server/internal/localdb"
)

// addSongWithTier — как addSong, но с заявленным quality_tier (для проверки понижения).
func (e *ctxEnv) addSongWithTier(t *testing.T, id, rel, content, tier string) string {
	t.Helper()
	local := filepath.Join(e.root, filepath.FromSlash(rel))
	if content != "" {
		if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(local, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	err := e.s.db.InsertTrackWithFile(
		localdb.NewTrack{ID: id, Artist: "Art " + id, Title: "Title " + id, NormalizedKey: "art " + id + "__title " + id},
		localdb.NewTrackFile{ID: "f_" + id, NormalizedKey: "art " + id + "__title " + id, FilePath: local,
			SizeBytes: int64(len(content)), QualityTier: tier})
	if err != nil {
		t.Fatal(err)
	}
	return local
}

// Один круг: считает cutoff для песен без него, не трогает уже посчитанные, понижает tier у
// подозрительных, ошибка декода пишет 0 (не NULL) — чтобы не пытаться на каждом круге заново.
func TestSpectrumKeeperPassAndDowngrade(t *testing.T) {
	e := ctxFixture(t)
	s := e.s
	f1 := e.addSongWithTier(t, "t1", "a/1.mp3", "content one", "excellent")  // «поддельный 320» — понизится
	f2 := e.addSongWithTier(t, "t2", "a/2.mp3", "content two", "excellent")  // настоящий — останется
	e.addSongWithTier(t, "t3", "a/3.mp3", "content three", "excellent")      // уже проверена раньше
	f4 := e.addSongWithTier(t, "t4", "a/4.mp3", "content four", "excellent") // ошибка декода

	if err := s.db.SetSpectralCutoff("t3", 19500, "", false); err != nil {
		t.Fatal(err)
	}

	var asked []string
	k := newSpectrumKeeper(s)
	k.computeFn = func(path string) (float64, error) {
		asked = append(asked, path)
		switch path {
		case f1:
			return 12000, nil // сильно ниже 18500 для excellent — подозрительно
		case f2:
			return 19800, nil // полный спектр — не трогаем
		case f4:
			return 0, errors.New("не смогла декодировать")
		}
		t.Fatalf("неожиданный путь: %s", path)
		return 0, nil
	}

	if err := k.pass(context.Background()); err != nil {
		t.Fatal(err)
	}

	if len(asked) != 3 || contains(asked, "") {
		t.Errorf("должна была спросить t1,t2,t4 (не t3 — уже проверена), спросила: %v", asked)
	}
	for _, want := range []string{f1, f2, f4} {
		if !contains(asked, want) {
			t.Errorf("не спросила %s", want)
		}
	}

	tier1 := tierOf(t, s, "t1")
	if tier1 != "good" {
		t.Errorf("t1 (cutoff=12000, было excellent) должен понизиться до good, получили %q", tier1)
	}
	tier2 := tierOf(t, s, "t2")
	if tier2 != "excellent" {
		t.Errorf("t2 (полный спектр) не должен был понизиться, получили %q", tier2)
	}
	tier4 := tierOf(t, s, "t4")
	if tier4 != "excellent" {
		t.Errorf("t4 (ошибка декода) не должен был понизиться, получили %q", tier4)
	}

	// t1/t2/t4 больше не должны попадать в следующую выборку.
	cands, err := s.db.TracksNeedingSpectrum(10)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range cands {
		if c.ID == "t1" || c.ID == "t2" || c.ID == "t4" {
			t.Errorf("%s с посчитанным cutoff не должна возвращаться в TracksNeedingSpectrum снова", c.ID)
		}
	}
}

func tierOf(t *testing.T, s *Service, id string) string {
	t.Helper()
	tier, err := s.db.TrackFileQualityTier(id)
	if err != nil {
		t.Fatal(err)
	}
	return tier
}
