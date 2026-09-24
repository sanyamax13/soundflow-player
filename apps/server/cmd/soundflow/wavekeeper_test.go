package main

import (
	"context"
	"errors"
	"testing"
)

func waveformOf(t *testing.T, s *Service, id string) ([]byte, bool) {
	t.Helper()
	b, found, err := s.db.Waveform(id)
	if err != nil {
		t.Fatal(err)
	}
	return b, found
}

// Один круг: считает волну для песен без неё, не трогает уже посчитанные, не смогла (ошибка
// декода) — пишет пустой срез (не NULL), чтобы не пытаться на каждом круге заново.
func TestWaveformKeeperPassComputesMissingOnly(t *testing.T) {
	e := ctxFixture(t)
	s := e.s
	f1 := e.addSong(t, "t1", "a/1.mp3", "content one")
	e.addSong(t, "t2", "a/2.mp3", "content two")
	f3 := e.addSong(t, "t3", "a/3.mp3", "content three — will fail to decode")

	// t2 уже посчитана раньше — трогать не должны.
	if err := s.db.SetWaveform("t2", []byte{10, 20, 30}); err != nil {
		t.Fatal(err)
	}

	var asked []string
	k := newWaveformKeeper(s)
	k.computeFn = func(path string) ([]byte, error) {
		asked = append(asked, path)
		switch path {
		case f1:
			return []byte{1, 2, 3, 4}, nil
		case f3:
			return nil, errors.New("не смогла декодировать")
		}
		t.Fatalf("неожиданный путь: %s", path)
		return nil, nil
	}

	if err := k.pass(context.Background()); err != nil {
		t.Fatal(err)
	}

	if len(asked) != 2 || !contains(asked, f1) || !contains(asked, f3) {
		t.Errorf("должна была спросить только t1 и t3, спросила: %v", asked)
	}

	b1, found1 := waveformOf(t, s, "t1")
	if !found1 || string(b1) != string([]byte{1, 2, 3, 4}) {
		t.Errorf("t1: %v найдена=%v", b1, found1)
	}
	b2, found2 := waveformOf(t, s, "t2")
	if !found2 || string(b2) != string([]byte{10, 20, 30}) {
		t.Errorf("t2 не должна была тронуться: %v найдена=%v", b2, found2)
	}
	b3, found3 := waveformOf(t, s, "t3")
	if found3 || len(b3) != 0 {
		t.Errorf("t3: ошибка декода — found должен быть false (пустой срез, не NULL), получили %v/%v", b3, found3)
	}
	// НО t3 больше не должна попадать в следующую выборку (пустой срез — не NULL).
	cands, err := s.db.TracksNeedingWaveform(10)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range cands {
		if c.ID == "t3" {
			t.Error("t3 с пустым результатом не должна возвращаться в TracksNeedingWaveform снова")
		}
	}
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
