package litestore

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"soundflow/server/internal/db"
	"soundflow/server/internal/localdb"
)

func openStore(t *testing.T) *Store {
	t.Helper()
	d, err := localdb.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return New(d)
}

func TestSaveSyncSchedulesRecomputeOnTasteSignal(t *testing.T) {
	s := openStore(t)
	// без вкусового сигнала — не планируем пересчёт
	_, err := s.SaveSync(context.Background(), db.Device{ID: "d"}, []db.SyncEvent{
		{UUID: "u1", Kind: "download", TrackID: "t1", Payload: json.RawMessage(`{}`), ClientTS: 1},
	})
	if err != nil {
		t.Fatal(err)
	}
	if s.recomputeRunning.Load() {
		t.Error("download-событие не должно планировать пересчёт вкуса")
	}

	// с лайком — планируем (и он не «уже идёт» вечно — дожидаемся конца)
	_, err = s.SaveSync(context.Background(), db.Device{ID: "d"}, []db.SyncEvent{
		{UUID: "u2", Kind: "like", TrackID: "t1", Payload: json.RawMessage(`{}`), ClientTS: 2},
	})
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for s.recomputeRunning.Load() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if s.recomputeRunning.Load() {
		t.Error("пересчёт после like-события не завершился за 2с")
	}
}

func TestSaveSyncRecomputeDebounced(t *testing.T) {
	s := openStore(t)
	s.lastRecompute = time.Now() // как будто только что пересчитали
	_, err := s.SaveSync(context.Background(), db.Device{ID: "d"}, []db.SyncEvent{
		{UUID: "u1", Kind: "like", TrackID: "t1", Payload: json.RawMessage(`{}`), ClientTS: 1},
	})
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	if s.recomputeRunning.Load() {
		t.Error("пересчёт внутри 5-минутного окна дебаунса не должен запускаться")
	}
}
