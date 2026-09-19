package api

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"soundflow/server/internal/db"
	"soundflow/server/internal/litestore"
	"soundflow/server/internal/localdb"
	"soundflow/server/internal/pathmap"
	"soundflow/server/internal/quality"
)

// fakeGate запоминает, что ему отдали; wantErr — как будто база шлюза сломалась.
type fakeGate struct {
	held    []HeldErase
	wantErr error
}

func (g *fakeGate) HoldErase(_ context.Context, h HeldErase) error {
	if g.wantErr != nil {
		return g.wantErr
	}
	g.held = append(g.held, h)
	return nil
}

// gateFixture — SQLite-база с одним треком и настоящим файлом во временной папке.
func gateFixture(t *testing.T) (st *litestore.Store, pm pathmap.Mapper, trackID, local, normKey string) {
	t.Helper()
	d, err := localdb.Open(filepath.Join(t.TempDir(), "gate.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	st = litestore.New(d)

	root := t.TempDir()
	local = filepath.Join(root, "Artist - Song.mp3")
	if err := os.WriteFile(local, []byte("audio-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	pm = pathmap.New(pathmap.Pair{Canonical: `E:\canon`, Local: root})

	trackID = "t_gate_1"
	normKey = quality.NormalizedKey("Artist", "Song")
	if err := st.InsertTrackWithFile(context.Background(),
		db.NewTrack{ID: trackID, Artist: "Artist", Title: "Song", NormalizedKey: normKey, ReleaseKind: "studio"},
		db.NewTrackFile{ID: trackID + "_f", NormalizedKey: normKey, FilePath: pm.ToCanonical(local), MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
	); err != nil {
		t.Fatal(err)
	}
	return st, pm, trackID, local, normKey
}

func deleteEvent(uuid, trackID, reason string) db.SyncEvent {
	payload := json.RawMessage(`{}`)
	if reason != "" {
		payload = json.RawMessage(`{"reason":"` + reason + `"}`)
	}
	return db.SyncEvent{UUID: uuid, Kind: "delete", TrackID: trackID, Payload: payload}
}

// С шлюзом (программа на компьютере): файл НЕ стирается, ждёт подтверждения;
// метка «больше не качать» стоит сразу (Alex TG 19943/19948).
func TestHandleDeleteEventsWithGateHoldsFile(t *testing.T) {
	st, pm, trackID, local, normKey := gateFixture(t)
	gate := &fakeGate{}
	s := &Server{DB: st, PathMap: pm, EraseGate: gate}

	s.handleDeleteEvents(context.Background(), []db.SyncEvent{deleteEvent("u1", trackID, "dislike")}, []string{"u1"})

	if _, err := os.Stat(local); err != nil {
		t.Fatalf("файл должен лежать до подтверждения: %v", err)
	}
	if len(gate.held) != 1 {
		t.Fatalf("шлюз должен получить 1 песню, получил %d", len(gate.held))
	}
	h := gate.held[0]
	if h.TrackID != trackID || h.Artist != "Artist" || h.Title != "Song" || h.Reason != "dislike" || h.Bytes != int64(len("audio-bytes")) {
		t.Errorf("не то отдали шлюзу: %+v", h)
	}
	if h.Path != pm.ToCanonical(local) {
		t.Errorf("шлюзу нужен канонический путь %q, получил %q", pm.ToCanonical(local), h.Path)
	}
	if kind, _ := st.LegacyMarkKind(context.Background(), normKey); kind != "blocked" {
		t.Errorf("метка blocked должна стоять сразу, получил %q", kind)
	}
}

// Шлюз сломался — файл всё равно не трогаем (лучше оставить, чем стереть без
// ведома Alex).
func TestHandleDeleteEventsGateErrorKeepsFile(t *testing.T) {
	st, pm, trackID, local, _ := gateFixture(t)
	s := &Server{DB: st, PathMap: pm, EraseGate: &fakeGate{wantErr: os.ErrPermission}}

	s.handleDeleteEvents(context.Background(), []db.SyncEvent{deleteEvent("u1", trackID, "dislike")}, []string{"u1"})

	if _, err := os.Stat(local); err != nil {
		t.Fatalf("при ошибке шлюза файл обязан остаться: %v", err)
	}
}

// Без шлюза (как раньше): файл стирается сразу.
func TestHandleDeleteEventsWithoutGateErasesNow(t *testing.T) {
	st, pm, trackID, local, normKey := gateFixture(t)
	s := &Server{DB: st, PathMap: pm}

	s.handleDeleteEvents(context.Background(), []db.SyncEvent{deleteEvent("u1", trackID, "dislike")}, []string{"u1"})

	if _, err := os.Stat(local); !os.IsNotExist(err) {
		t.Errorf("без шлюза файл должен исчезнуть сразу, stat: %v", err)
	}
	if kind, _ := st.LegacyMarkKind(context.Background(), normKey); kind != "blocked" {
		t.Errorf("метка blocked должна стоять, получил %q", kind)
	}
}

// «Плохое качество»/«не та версия» шлюз не проходят: программа сама ищет замену,
// файл стирается сразу (Alex: в окно эти причины не попадают).
func TestHandleDeleteEventsBadQualityBypassesGate(t *testing.T) {
	for _, reason := range []string{"bad_quality", "wrong_version"} {
		t.Run(reason, func(t *testing.T) {
			st, pm, trackID, local, _ := gateFixture(t)
			gate := &fakeGate{}
			s := &Server{DB: st, PathMap: pm, EraseGate: gate} // Acquire == nil: замену не ищем

			s.handleDeleteEvents(context.Background(), []db.SyncEvent{deleteEvent("u1", trackID, reason)}, []string{"u1"})

			if len(gate.held) != 0 {
				t.Errorf("шлюз не должен получать %s, получил %+v", reason, gate.held)
			}
			if _, err := os.Stat(local); !os.IsNotExist(err) {
				t.Errorf("файл должен быть стёрт сразу, stat: %v", err)
			}
		})
	}
}

// Дубль события (не в accepted) и с шлюзом ничего не трогает.
func TestHandleDeleteEventsGateIgnoresUnaccepted(t *testing.T) {
	st, pm, trackID, local, _ := gateFixture(t)
	gate := &fakeGate{}
	s := &Server{DB: st, PathMap: pm, EraseGate: gate}

	s.handleDeleteEvents(context.Background(), []db.SyncEvent{deleteEvent("dup", trackID, "dislike")}, nil)

	if len(gate.held) != 0 {
		t.Errorf("дубль не должен доходить до шлюза: %+v", gate.held)
	}
	if _, err := os.Stat(local); err != nil {
		t.Errorf("файл не должен был тронуться: %v", err)
	}
}
