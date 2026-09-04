package db

import (
	"context"
	"os"
	"testing"
	"time"
)

// testPool даёт живой пул или пропускает тест, если базы нет
// (в CI/на машине без docker compose up).
func testPool(t *testing.T) *Pool {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		url = "postgres://soundflow:soundflow_dev@localhost:5433/soundflow?sslmode=disable"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	p, err := Open(ctx, url)
	if err != nil {
		t.Skipf("нет базы (%v) — пропускаю", err)
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		t.Skipf("база не отвечает (%v) — пропускаю", err)
	}
	return p
}

func TestSaveSyncDedupe(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()

	dev := Device{ID: "test-dev-" + time.Now().Format("150405.000000")}
	// Порядок важен: чистим тестовые строки и только потом закрываем пул.
	// t.Cleanup — LIFO, поэтому Close регистрируем первым.
	t.Cleanup(p.Close)
	t.Cleanup(func() {
		_, _ = p.p.Exec(ctx, `DELETE FROM sync_events WHERE device_id = $1`, dev.ID)
		_, _ = p.p.Exec(ctx, `DELETE FROM devices WHERE id = $1`, dev.ID)
	})

	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	ev := []SyncEvent{{UUID: dev.ID + "-e1", Kind: "like", TrackID: "t1"}}

	acc, err := p.SaveSync(ctx, dev, ev)
	if err != nil {
		t.Fatalf("save #1: %v", err)
	}
	if len(acc) != 1 {
		t.Fatalf("ждал 1 принятое событие, получил %d", len(acc))
	}

	// Тот же uuid второй раз — сервер не принимает.
	acc2, err := p.SaveSync(ctx, dev, ev)
	if err != nil {
		t.Fatalf("save #2: %v", err)
	}
	if len(acc2) != 0 {
		t.Fatalf("дубль приняли: %d", len(acc2))
	}

	// Новое событие рядом со старым — принимается только новое.
	ev2 := []SyncEvent{
		{UUID: dev.ID + "-e1", Kind: "like", TrackID: "t1"},
		{UUID: dev.ID + "-e2", Kind: "delete", TrackID: "t2"},
	}
	acc3, err := p.SaveSync(ctx, dev, ev2)
	if err != nil {
		t.Fatalf("save #3: %v", err)
	}
	if len(acc3) != 1 || acc3[0] != dev.ID+"-e2" {
		t.Fatalf("ждал только e2, получил %v", acc3)
	}

	last, total, err := p.SyncReport(ctx, dev.ID)
	if err != nil {
		t.Fatalf("report: %v", err)
	}
	if total != 2 {
		t.Fatalf("ждал total=2, получил %d", total)
	}
	if last == nil {
		t.Fatalf("last_sync_at пуст")
	}
}

func TestAdminStatusShape(t *testing.T) {
	p := testPool(t)
	ctx := context.Background()
	t.Cleanup(p.Close)
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	st, err := p.AdminStatus(ctx)
	if err != nil {
		t.Fatalf("AdminStatus: %v", err)
	}
	if st.Tracks != 0 || st.TrackFiles != 0 {
		t.Errorf("каталог должен быть пуст: tracks=%d files=%d", st.Tracks, st.TrackFiles)
	}
	if len(st.Migrations) < 2 {
		t.Errorf("ждал ≥2 миграции, получил %v", st.Migrations)
	}
	if st.EventsByKind == nil {
		t.Error("EventsByKind не должно быть nil")
	}

	devs, err := p.ListDevices(ctx)
	if err != nil {
		t.Fatalf("ListDevices: %v", err)
	}
	if devs == nil {
		t.Error("ListDevices вернул nil вместо пустого списка")
	}

	ev, err := p.RecentEvents(ctx, 10)
	if err != nil {
		t.Fatalf("RecentEvents: %v", err)
	}
	if ev == nil {
		t.Error("RecentEvents вернул nil вместо пустого списка")
	}
}
