package main

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"soundflow/server/internal/localdb"
)

func TestPathRootAndFolder(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("пути с буквой диска")
	}
	cases := []struct{ in, root, folder string }{
		{`G:\музыка\HitZone\a.mp3`, `G:\музыка`, `G:\музыка\HitZone`},
		{`G:\музыка\HitZone\Диск 1\a.mp3`, `G:\музыка`, `G:\музыка\HitZone`},
		{`G:/музыка/Яндекс/x.mp3`, `G:\музыка`, `G:\музыка\Яндекс`},
		{`G:\музыка\a.mp3`, `G:\музыка`, `G:\музыка`},
		{`G:\a.mp3`, `G:\`, `G:\`},
	}
	for _, c := range cases {
		if got := pathRoot(c.in); got != c.root {
			t.Errorf("pathRoot(%q)=%q, ждали %q", c.in, got, c.root)
		}
		if got := pathFolder(c.in); got != c.folder {
			t.Errorf("pathFolder(%q)=%q, ждали %q", c.in, got, c.folder)
		}
	}
}

func reconFixture(t *testing.T) (*ctxEnv, *reconciler, *time.Time) {
	t.Helper()
	e := ctxFixture(t)
	r := newReconciler(e.s)
	e.s.recon = r
	clock := time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC)
	r.now = func() time.Time { return clock }
	return e, r, &clock
}

func songCount(t *testing.T, e *ctxEnv) int {
	t.Helper()
	var n int
	if err := e.s.db.SQL().QueryRow(`SELECT COUNT(*) FROM tracks`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func logHas(t *testing.T, e *ctxEnv, sub string) bool {
	t.Helper()
	list, err := e.s.db.RecentServerLog(50)
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range list {
		if strings.Contains(it.Detail, sub) {
			return true
		}
	}
	return false
}

// Файла нет только что — ждём выдержку (две проверки подряд), потом сама убирает; песня с файлом остаётся.
func TestReconcileAutoWaitsForGraceThenRemoves(t *testing.T) {
	e, r, clock := reconFixture(t)
	e.addSong(t, "gone", "a/gone.mp3", "") // файла на диске нет
	e.addSong(t, "here", "a/here.mp3", "x")

	r.auto()
	if songCount(t, e) != 2 {
		t.Fatal("убрала сразу, без выдержки")
	}
	*clock = clock.Add(5 * time.Minute)
	r.auto()
	if songCount(t, e) != 2 {
		t.Fatal("убрала раньше выдержки (5 минут)")
	}
	*clock = clock.Add(6 * time.Minute)
	r.auto()
	if songCount(t, e) != 1 || inCatalog(t, e.s, "gone") || !inCatalog(t, e.s, "here") {
		t.Fatalf("после выдержки должна остаться только песня с файлом, песен %d", songCount(t, e))
	}
	if !logHas(t, e, "каталог сверен с диском") {
		t.Error("в журнале нет записи об уборке")
	}
}

// Файл вернулся на место до конца выдержки — учёт «пропал» сбрасывается, песня не убирается.
func TestReconcileForgetsFilesThatReturned(t *testing.T) {
	e, r, clock := reconFixture(t)
	local := e.addSong(t, "back", "a/back.mp3", "")

	r.auto()
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(local, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(15 * time.Minute)
	r.auto() // файл на месте — забыта
	if err := os.Remove(local); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(5 * time.Minute)
	r.auto() // пропал снова, но отсчёт пошёл заново
	if songCount(t, e) != 1 {
		t.Fatal("убрала песню, чей файл возвращался на место")
	}
}

// Много пропало разом (диск отвалился, папку убрали целиком) — сама не убирает, ждёт решения в окне.
func TestReconcileAutoDoesNotTouchMassDisappearance(t *testing.T) {
	e, r, clock := reconFixture(t)
	for i := 0; i < reconcileAutoMax+1; i++ {
		e.addSong(t, fmt.Sprintf("m%04d", i), fmt.Sprintf("many/%04d.mp3", i), "")
	}
	total := songCount(t, e)
	r.auto()
	*clock = clock.Add(time.Hour)
	r.auto()
	if songCount(t, e) != total {
		t.Fatalf("сама убрала при массовой пропаже: было %d, стало %d", total, songCount(t, e))
	}
	rec := httptest.NewRecorder()
	e.s.hMissing(rec, httptest.NewRequest("GET", "/api/catalog/missing", nil))
	var out struct {
		Files        int  `json:"files"`
		NeedsConfirm bool `json:"needs_confirm"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	if out.Files != total || !out.NeedsConfirm {
		t.Errorf("окно должно спросить: %+v", out)
	}
}

// Кнопка «Убрать из каталога»: убирает всё пропавшее, делает копию базы, песни с файлом и метки остаются.
func TestMissingCleanRemovesAllAndBacksUp(t *testing.T) {
	e, _, _ := reconFixture(t)
	for i := 0; i < bigDeleteThreshold+5; i++ {
		e.addSong(t, fmt.Sprintf("d%03d", i), fmt.Sprintf("dead/%03d.mp3", i), "")
	}
	e.addSong(t, "live", "live/l.mp3", "x")
	if _, err := e.s.db.SQL().Exec(`INSERT INTO legacy_marks (normalized_key,kind,artist,title,marked_at)
		VALUES ('k','favorite','A','T','2026-09-21T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	e.s.hMissingClean(rec, httptest.NewRequest("POST", "/api/catalog/missing/clean", nil))
	if rec.Code != 200 {
		t.Fatalf("код %d: %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Songs, Files int
		Backup       string
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	if out.Songs != bigDeleteThreshold+5 || out.Files != bigDeleteThreshold+5 {
		t.Errorf("убрано %+v", out)
	}
	if out.Backup == "" {
		t.Fatal("перед большой уборкой копия базы обязательна")
	}
	if fi, err := os.Stat(out.Backup); err != nil || fi.Size() == 0 {
		t.Errorf("копии базы нет: %v", err)
	}
	if songCount(t, e) != 1 || !inCatalog(t, e.s, "live") {
		t.Errorf("должна остаться песня с файлом, песен %d", songCount(t, e))
	}
	var marks int
	_ = e.s.db.SQL().QueryRow(`SELECT COUNT(*) FROM legacy_marks`).Scan(&marks)
	if marks != 1 {
		t.Error("метка избранного пропала")
	}
}

// Корень пути недоступен (диск не подключён) — такие файлы пропавшими не считаем.
func TestFindMissingSkipsUnreachableRoot(t *testing.T) {
	e := ctxFixture(t)
	e.addSong(t, "real", "a/real.mp3", "") // корень есть, файла нет — пропал
	absent := `Z:\нет-такой-папки\x.mp3`
	if runtime.GOOS != "windows" {
		absent = "/нет-такой-папки/x.mp3"
	}
	key := "art off__title off"
	if err := e.s.db.InsertTrackWithFile(
		localdb.NewTrack{ID: "off", Artist: "Art off", Title: "Title off", NormalizedKey: key},
		localdb.NewTrackFile{ID: "f_off", NormalizedKey: key, FilePath: absent}); err != nil {
		t.Fatal(err)
	}
	rep := e.s.findMissing()
	if len(rep.Files) != 1 || rep.Files[0].TrackID != "real" {
		t.Fatalf("ждали только «real», получили %+v", rep.Files)
	}
}

// Файл переехал: прежний пропал, этот на месте — запись перенаправляется; если прежний на месте — это копия.
func TestRelinkMovedFile(t *testing.T) {
	e := ctxFixture(t)
	oldLocal := e.addSong(t, "mv", "old/mv.mp3", "") // на старом месте файла нет
	newLocal := filepath.Join(e.root, "new", "mv.mp3")
	if err := os.MkdirAll(filepath.Dir(newLocal), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(newLocal, []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	key := "art mv__title mv"
	if !e.s.relinkMoved(key, newLocal) {
		t.Fatal("перенос не распознан")
	}
	if _, p, ok, _ := e.s.db.FileByKey(key); !ok || p != newLocal {
		t.Errorf("путь после переноса %q, ждали %q", p, newLocal)
	}
	if e.s.relinkMoved(key, newLocal) {
		t.Error("повторный вызов с тем же путём — не перенос")
	}

	// копия: прежний файл на месте
	e.addSong(t, "cp", "old/cp.mp3", "x")
	other := filepath.Join(e.root, "new", "cp.mp3")
	if err := os.WriteFile(other, []byte("y"), 0o644); err != nil {
		t.Fatal(err)
	}
	if e.s.relinkMoved("art cp__title cp", other) {
		t.Error("копию приняли за перенос")
	}
	_ = oldLocal
}
