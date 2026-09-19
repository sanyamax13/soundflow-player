package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/pathmap"
)

func removalsFixture(t *testing.T) (*Service, pathmap.Mapper, string) {
	t.Helper()
	d, err := localdb.Open(filepath.Join(t.TempDir(), "r.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	root := t.TempDir()
	return &Service{db: d}, pathmap.New(pathmap.Pair{Canonical: `E:\canon`, Local: root}), root
}

func addPending(t *testing.T, s *Service, pm pathmap.Mapper, root, id, name string, content string) string {
	t.Helper()
	local := filepath.Join(root, name)
	if content != "" {
		if err := os.WriteFile(local, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.db.AddPendingRemoval(localdb.PendingRemoval{
		TrackID: id, Artist: "A", Title: id, FilePath: pm.ToCanonical(local), Bytes: 999, Reason: "dislike",
	}); err != nil {
		t.Fatal(err)
	}
	return local
}

// Стирается только то, что передали в ids; остальное ждёт и файл цел.
func TestEraseRemovalsOnlyRequested(t *testing.T) {
	s, pm, root := removalsFixture(t)
	f1 := addPending(t, s, pm, root, "t1", "one.mp3", "12345")
	f2 := addPending(t, s, pm, root, "t2", "two.mp3", "abc")

	res := s.eraseRemovals([]string{"t1", "t1", "", "nope"}, pm) // дубль, пустой и чужой id игнорируются

	if res.Erased != 1 || res.Failed != 0 || res.FreedBytes != 5 {
		t.Errorf("результат: %+v (ждал erased=1 failed=0 freed=5 — реальный размер, не 999 из записи)", res)
	}
	if _, err := os.Stat(f1); !os.IsNotExist(err) {
		t.Errorf("t1 должен быть стёрт, stat: %v", err)
	}
	if _, err := os.Stat(f2); err != nil {
		t.Errorf("t2 не просили — обязан лежать: %v", err)
	}
	left, _ := s.db.PendingRemovals()
	if len(left) != 1 || left[0].TrackID != "t2" {
		t.Errorf("в ожидании должен остаться только t2, получил %+v", left)
	}
}

// Файла уже нет (стёрли руками) — запись всё равно закрываем, освобождено 0.
func TestEraseRemovalsFileAlreadyGone(t *testing.T) {
	s, pm, root := removalsFixture(t)
	addPending(t, s, pm, root, "t1", "gone.mp3", "") // файл не создаём

	res := s.eraseRemovals([]string{"t1"}, pm)

	if res.Erased != 1 || res.FreedBytes != 0 {
		t.Errorf("результат: %+v", res)
	}
	if left, _ := s.db.PendingRemovals(); len(left) != 0 {
		t.Errorf("запись должна закрыться: %+v", left)
	}
}

// Путь оказался папкой — не стираем, песня остаётся в ожидании.
func TestEraseRemovalsRefusesDirectory(t *testing.T) {
	s, pm, root := removalsFixture(t)
	dir := filepath.Join(root, "album")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "x.mp3"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := s.db.AddPendingRemoval(localdb.PendingRemoval{TrackID: "t1", FilePath: pm.ToCanonical(dir)}); err != nil {
		t.Fatal(err)
	}

	res := s.eraseRemovals([]string{"t1"}, pm)

	if res.Erased != 0 || res.Failed != 1 {
		t.Errorf("результат: %+v", res)
	}
	if _, err := os.Stat(filepath.Join(dir, "x.mp3")); err != nil {
		t.Errorf("содержимое папки должно уцелеть: %v", err)
	}
	if left, _ := s.db.PendingRemovals(); len(left) != 1 {
		t.Errorf("песня должна остаться в ожидании: %+v", left)
	}
}

func TestRemovalsHandlers(t *testing.T) {
	s, pm, root := removalsFixture(t)
	s.pm = pm
	addPending(t, s, pm, root, "t1", "one.mp3", "12345")

	rec := httptest.NewRecorder()
	s.hRemovals(rec, httptest.NewRequest("GET", "/api/removals", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"count":1`) || !strings.Contains(rec.Body.String(), `"track_id":"t1"`) {
		t.Errorf("список: %d %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "file_path") || strings.Contains(rec.Body.String(), `E:\canon`) {
		t.Errorf("путь к файлу наружу отдавать не нужно: %s", rec.Body.String())
	}

	rec = httptest.NewRecorder()
	s.hRemovalsConfirm(rec, httptest.NewRequest("POST", "/api/removals/confirm", strings.NewReader("не json")))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("битое тело: ждал 400, получил %d", rec.Code)
	}

	rec = httptest.NewRecorder()
	s.hRemovalsConfirm(rec, httptest.NewRequest("POST", "/api/removals/confirm", strings.NewReader(`{"ids":["t1"]}`)))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"erased":1`) {
		t.Errorf("подтверждение: %d %s", rec.Code, rec.Body.String())
	}
}
