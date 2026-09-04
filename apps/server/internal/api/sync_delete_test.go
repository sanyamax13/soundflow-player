package api

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"soundflow/server/internal/db"
	"soundflow/server/internal/pathmap"
	"soundflow/server/internal/quality"
)

func testDB(t *testing.T) *db.Pool {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		url = "postgres://soundflow:soundflow_dev@localhost:5433/soundflow?sslmode=disable"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	p, err := db.Open(ctx, url)
	if err != nil {
		t.Skipf("нет базы (%v)", err)
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		t.Skipf("база молчит (%v)", err)
	}
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(p.Close)
	return p
}

// Alex удалил трек на телефоне — сервер должен пометить его blocked и убрать
// файл в _trash (не удалить насовсем).
func TestHandleDeleteEventsMovesFileAndBlocks(t *testing.T) {
	p := testDB(t)
	ctx := context.Background()

	root := t.TempDir()
	rel := "Artist - Song.mp3"
	local := filepath.Join(root, rel)
	if err := os.WriteFile(local, []byte("audio"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	pm := pathmap.New(pathmap.Pair{Canonical: `E:\canon`, Local: root})
	canonical := pm.ToCanonical(local)

	trackID := "t_delevt_" + time.Now().Format("150405.000000")
	fileID := trackID + "_f"
	artist, title := "DelEvt Artist", "Song"
	normKey := quality.NormalizedKey(artist, title)
	t.Cleanup(func() {
		_ = p.DeleteTrackByKey(context.Background(), normKey)
		_ = p.DeleteLegacyMark(context.Background(), normKey)
	})
	if err := p.InsertTrackWithFile(ctx,
		db.NewTrack{ID: trackID, Artist: artist, Title: title, NormalizedKey: normKey, ReleaseKind: "studio"},
		db.NewTrackFile{ID: fileID, NormalizedKey: normKey, FilePath: canonical, MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
	); err != nil {
		t.Fatalf("insert: %v", err)
	}

	s := &Server{DB: p, PathMap: pm}
	events := []db.SyncEvent{{UUID: "u1", Kind: "delete", TrackID: trackID}}
	s.handleDeleteEvents(ctx, events, []string{"u1"})

	kind, err := p.LegacyMarkKind(ctx, normKey)
	if err != nil || kind != "blocked" {
		t.Fatalf("ждал blocked, получил %q %v", kind, err)
	}

	if _, err := os.Stat(local); !os.IsNotExist(err) {
		t.Errorf("исходный файл должен исчезнуть, stat: %v", err)
	}
	trashed := filepath.Join(root, "_trash", rel)
	if _, err := os.Stat(trashed); err != nil {
		t.Errorf("файл должен оказаться в _trash: %v", err)
	}
}

// Событие, не попавшее в accepted (дубль), файл не трогает.
func TestHandleDeleteEventsIgnoresUnaccepted(t *testing.T) {
	p := testDB(t)
	ctx := context.Background()

	root := t.TempDir()
	local := filepath.Join(root, "X - Y.mp3")
	if err := os.WriteFile(local, []byte("audio"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	pm := pathmap.New(pathmap.Pair{Canonical: `E:\canon2`, Local: root})
	canonical := pm.ToCanonical(local)

	trackID := "t_delevt2_" + time.Now().Format("150405.000000")
	normKey := quality.NormalizedKey("X", "Y")
	t.Cleanup(func() {
		_ = p.DeleteTrackByKey(context.Background(), normKey)
		_ = p.DeleteLegacyMark(context.Background(), normKey)
	})
	if err := p.InsertTrackWithFile(ctx,
		db.NewTrack{ID: trackID, Artist: "X", Title: "Y", NormalizedKey: normKey, ReleaseKind: "studio"},
		db.NewTrackFile{ID: trackID + "_f", NormalizedKey: normKey, FilePath: canonical, MimeType: "audio/mpeg", Source: "test", QualityTier: "excellent"},
	); err != nil {
		t.Fatalf("insert: %v", err)
	}

	s := &Server{DB: p, PathMap: pm}
	events := []db.SyncEvent{{UUID: "dup1", Kind: "delete", TrackID: trackID}}
	s.handleDeleteEvents(ctx, events, nil) // ничего не accepted — дубль

	if _, err := os.Stat(local); err != nil {
		t.Errorf("файл не должен был тронуться: %v", err)
	}
	if kind, _ := p.LegacyMarkKind(ctx, normKey); kind != "" {
		t.Errorf("метка не должна была появиться, получил %q", kind)
	}
}
