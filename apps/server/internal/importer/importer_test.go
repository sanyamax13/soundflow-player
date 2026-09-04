package importer

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

// Файлы без реальных тегов — Scan должен разобрать «Артист - Название» из
// имени. Настоящих mp3 не пишем, для этого сценария и не нужно: readTags
// вернёт пусто на не-аудио байтах, сработает fromFilename.
func TestScanImportsFromFilename(t *testing.T) {
	p := testDB(t)
	ctx := context.Background()
	tag := "Imp" + time.Now().Format("150405.000000")

	dir := t.TempDir()
	good := filepath.Join(dir, tag+" Artist - Good Song.mp3")
	if err := os.WriteFile(good, []byte("not really audio"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	// Без " - " в имени — не разберём, должен уйти в Skipped.
	bad := filepath.Join(dir, "NoDelimiter.mp3")
	if err := os.WriteFile(bad, []byte("x"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	// Не аудио-расширение — Scan не должен даже тронуть.
	if err := os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	keyGood := quality.NormalizedKey(tag+" Artist", "Good Song")
	t.Cleanup(func() { _ = p.DeleteTrackByKey(context.Background(), keyGood) })

	pm := pathmap.New() // no-op — путь на диске совпадает с каноническим
	res, err := Scan(ctx, p, pm, []string{dir})
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if res.Scanned != 2 {
		t.Errorf("Scanned: ждал 2 (mp3), получил %d", res.Scanned)
	}
	if res.Imported != 1 {
		t.Errorf("Imported: ждал 1, получил %+v", res)
	}
	if res.Skipped != 1 {
		t.Errorf("Skipped: ждал 1 (без разделителя), получил %+v", res)
	}

	tr, err := p.TrackByKey(ctx, keyGood)
	if err != nil || tr == nil {
		t.Fatalf("трек не найден в каталоге: %v %v", tr, err)
	}
	if tr.Artist != tag+" Artist" || tr.Title != "Good Song" {
		t.Errorf("разобрано неверно: %+v", tr)
	}

	// Повторный обход того же файла — уже в каталоге, должен уйти в Skipped,
	// не задублировать.
	res2, err := Scan(ctx, p, pm, []string{dir})
	if err != nil {
		t.Fatalf("Scan#2: %v", err)
	}
	if res2.Imported != 0 {
		t.Errorf("повторный обход не должен ничего добавить: %+v", res2)
	}
}

// Трек, отмеченный в legacy_marks как blocked (Alex удалил/скрыл в старом
// плеере) — импорт не должен его вернуть в каталог.
func TestScanSkipsLegacyBlocked(t *testing.T) {
	p := testDB(t)
	ctx := context.Background()
	tag := "ImpBlk" + time.Now().Format("150405.000000")
	artist, title := tag+" Artist", "Hidden Song"
	key := quality.NormalizedKey(artist, title)

	if _, err := p.LegacyMarksInsert(ctx, map[string]db.LegacyMark{
		key: {Key: key, Kind: "blocked", Artist: artist, Title: title},
	}); err != nil {
		t.Fatalf("seed mark: %v", err)
	}
	t.Cleanup(func() {
		_ = p.DeleteTrackByKey(context.Background(), key)
		_ = p.DeleteLegacyMark(context.Background(), key)
	})

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, artist+" - "+title+".mp3"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	res, err := Scan(ctx, p, pathmap.New(), []string{dir})
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if res.Imported != 0 || res.Skipped != 1 {
		t.Fatalf("ждал 0 imported / 1 skipped, получил %+v", res)
	}
	if tr, _ := p.TrackByKey(ctx, key); tr != nil {
		t.Error("заблокированный трек не должен попасть в каталог")
	}
}
