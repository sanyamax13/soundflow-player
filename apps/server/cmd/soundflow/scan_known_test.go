package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"soundflow/server/internal/localdb"
)

func waitScan(t *testing.T, s *Service) Job {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		for _, j := range s.jobs.Status() {
			if j.Kind == "scan" && !j.Running {
				return j
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("скан не закончился")
	return Job{}
}

func trackCount(t *testing.T, s *Service) int {
	t.Helper()
	var n int
	if err := s.db.SQL().QueryRow(`SELECT COUNT(*) FROM tracks`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// Скачанная песня записана в каталог с официальным названием («МагаЗина»), а файл лежит под
// именем из запроса («Анонс - Зина.mp3») — и в базе путь записан с другим регистром. Скан при
// следующем запуске не должен добавлять этот файл вторым разом (20.09.2026: три дубля сразу
// после замены программы); неизвестный файл добавляется как раньше.
func TestScanSkipsFileAlreadyInCatalogUnderAnotherName(t *testing.T) {
	e := ctxFixture(t)
	e.s.jobs = NewJobRunner(e.s)

	known := filepath.Join(e.root, "Яндекс", "Анонс", "Анонс - Зина.mp3")
	fresh := filepath.Join(e.root, "Яндекс", "Новый", "Новый - Песня.mp3")
	for _, p := range []string{known, fresh} {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// путь в базе — другого регистра, чем на диске (как G:\Музыка против G:\музыка)
	err := e.s.db.InsertTrackWithFile(
		localdb.NewTrack{ID: "t_acq", Artist: "Анонс", Title: "МагаЗина", NormalizedKey: "анонс__магазина"},
		localdb.NewTrackFile{ID: "f_acq", NormalizedKey: "анонс__магазина", FilePath: strings.ToUpper(known), Source: "yandex"})
	if err != nil {
		t.Fatal(err)
	}

	if e.s.jobs.StartScan(e.root) == "" {
		t.Fatal("скан не запустился")
	}
	j := waitScan(t, e.s)

	if !strings.Contains(j.Note, "добавлено 1,") {
		t.Errorf("ждали одну новую песню, итог скана: %q", j.Note)
	}
	if n := trackCount(t, e.s); n != 2 {
		t.Errorf("песен в каталоге %d, ждали 2 (скачанная + одна новая)", n)
	}
	var files int
	if err := e.s.db.SQL().QueryRow(`SELECT COUNT(*) FROM track_files WHERE lower(file_path) = lower(?)`, strings.ToUpper(known)).Scan(&files); err != nil {
		t.Fatal(err)
	}
	if files != 1 {
		t.Errorf("у скачанного файла %d записей, ждали 1", files)
	}

	// повторный скан ничего не добавляет
	e.s.jobs.mu.Lock()
	e.s.jobs.cur = nil
	e.s.jobs.mu.Unlock()
	if e.s.jobs.StartScan(e.root) == "" {
		t.Fatal("второй скан не запустился")
	}
	if j := waitScan(t, e.s); !strings.Contains(j.Note, "добавлено 0,") {
		t.Errorf("повторный скан: %q", j.Note)
	}
}

func TestPathKeyIgnoresCaseAndSlashes(t *testing.T) {
	a := localdb.PathKey(`G:\Музыка\Яндекс\Анонс\Анонс - Зина.mp3`)
	b := localdb.PathKey(`g:/музыка/яндекс/анонс/анонс - зина.MP3`)
	if a != b {
		t.Errorf("ключи разные: %q и %q", a, b)
	}
	if localdb.PathKey(`G:\a\b.mp3`) == localdb.PathKey(`G:\a\c.mp3`) {
		t.Errorf("разные файлы дали один ключ")
	}
}
