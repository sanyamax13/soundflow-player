package main

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"soundflow/server/internal/coverfind"
	"soundflow/server/internal/localdb"
)

func testJPEG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 300, 300))
	for y := 0; y < 300; y++ {
		for x := 0; x < 300; x++ {
			img.Set(x, y, color.RGBA{uint8(x * 3), uint8(y * 5), uint8((x * y) % 251), 255})
		}
	}
	var b bytes.Buffer
	if err := jpeg.Encode(&b, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func coverMarker(t *testing.T, s *Service, id string) string {
	t.Helper()
	var m string
	if err := s.db.SQL().QueryRow(`SELECT cover_url FROM tracks WHERE id=?`, id).Scan(&m); err != nil {
		t.Fatal(err)
	}
	return m
}

// keeperEnv — хранитель обложек на временной базе; «интернет» — своя функция поиска.
func keeperEnv(t *testing.T, search func(ctx context.Context, artist, title string) ([]coverfind.Candidate, error)) (*ctxEnv, *coverKeeper) {
	t.Helper()
	e := ctxFixture(t)
	e.s.jobs = NewJobRunner(e.s)
	k := newCoverKeeper(e.s)
	k.now = func() time.Time { return time.Date(2026, 9, 20, 12, 0, 0, 0, time.UTC) }
	k.newFinder = func() *coverfind.Finder {
		return &coverfind.Finder{Sources: []coverfind.Source{{Name: "test", Search: search}}}
	}
	return e, k
}

// Обложка уже есть (в папке, найдена раньше) — только метка; нет нигде — поиск: нашлась —
// файл в found_covers и метка «found», не нашлась — «none@сегодня»; файл недоступен и песня в
// чёрном списке — не трогаем.
func TestCoverKeeperPassMarksAndSearches(t *testing.T) {
	img := testJPEG(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(img) }))
	defer srv.Close()

	asked := map[string]bool{}
	e, k := keeperEnv(t, func(ctx context.Context, artist, title string) ([]coverfind.Candidate, error) {
		asked[title] = true
		if title == "Title c" {
			return []coverfind.Candidate{{Artists: []string{artist}, Title: title, Image: srv.URL + "/c.jpg"}}, nil
		}
		return []coverfind.Candidate{{Artists: []string{"Кто-то другой"}, Title: "Другая песня", Image: srv.URL + "/x.jpg"}}, nil
	})
	s := e.s
	dir := s.foundCoversDir()

	e.addSong(t, "a", "A/a.mp3", "x")
	if err := os.WriteFile(filepath.Join(e.root, "A", "cover.jpg"), img, 0o644); err != nil { // обложка-картинка в папке альбома
		t.Fatal(err)
	}
	e.addSong(t, "b", "B/b.mp3", "x")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "b.jpg"), img, 0o644); err != nil { // найдена раньше
		t.Fatal(err)
	}
	e.addSong(t, "c", "C/c.mp3", "x") // нигде нет — нашлась в интернете
	e.addSong(t, "d", "D/d.mp3", "x") // нигде нет — не нашлась
	e.addSong(t, "e", "E/e.mp3", "")  // файла на диске нет (диск не подключён)
	e.addSong(t, "f", "F/f.mp3", "x") // в чёрном списке
	if _, err := s.db.ImportBlocked([]localdb.BlockedMark{{NormalizedKey: "art f__title f"}}); err != nil {
		t.Fatal(err)
	}

	if err := k.pass(context.Background()); err != nil {
		t.Fatal(err)
	}

	want := map[string]string{"a": "folder", "b": "found", "c": "found", "d": "none@2026-09-20", "e": "", "f": ""}
	for id, w := range want {
		if got := coverMarker(t, s, id); got != w {
			t.Errorf("песня %s: метка %q, ждали %q", id, got, w)
		}
	}
	if b, err := os.ReadFile(filepath.Join(dir, "c.jpg")); err != nil || !bytes.HasPrefix(b, []byte{0xff, 0xd8, 0xff}) {
		t.Errorf("найденная обложка не записана как JPEG: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "d.jpg")); err == nil {
		t.Errorf("для не найденной песни файла быть не должно")
	}
	if _, err := os.Stat(filepath.Join(dir, "c.jpg.tmp")); err == nil {
		t.Errorf("временный файл остался")
	}
	for _, id := range []string{"a", "b", "e", "f"} {
		if asked["Title "+id] {
			t.Errorf("по песне %s искать в интернете не должны", id)
		}
	}

	// карточка «Ищу обложки» и итог в журнале
	var job *Job
	for _, j := range s.jobs.Status() {
		if j.Kind == "covers" {
			jc := j
			job = &jc
		}
	}
	if job == nil || job.Running || job.Total != 2 || job.Done != 2 || !strings.Contains(job.Note, "нашла 1, не нашла 1") {
		t.Errorf("карточка задачи: %+v", job)
	}

	// второй круг: всё уже помечено — искать больше нечего
	asked = map[string]bool{}
	if err := k.pass(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(asked) != 0 {
		t.Errorf("повторный круг не должен искать: %v", asked)
	}
}

// Нет интернета (ни один источник не ответил) — песни НЕ помечаются «не нашлась», следующий
// круг попробует снова; после нескольких таких подряд круг прерывается, а не долбит впустую.
func TestCoverKeeperOfflineLeavesSongsUnmarked(t *testing.T) {
	calls := 0
	e, k := keeperEnv(t, func(ctx context.Context, artist, title string) ([]coverfind.Candidate, error) {
		calls++
		return nil, fmt.Errorf("нет сети")
	})
	for i := 0; i < 30; i++ {
		id := fmt.Sprintf("t%02d", i)
		e.addSong(t, id, id+"/"+id+".mp3", "x")
	}
	if err := k.pass(context.Background()); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 30; i++ {
		id := fmt.Sprintf("t%02d", i)
		if m := coverMarker(t, e.s, id); m != "" {
			t.Errorf("песня %s помечена %q, хотя сети не было", id, m)
		}
	}
	if calls >= 30 {
		t.Errorf("круг должен прерваться после %d неудач подряд, а было %d запросов", coverOfflineStop, calls)
	}
}

// «Не нашлась» неделю назад и раньше — ищем снова; позавчерашнюю — нет.
func TestCoverKeeperRetriesOldNoneAfterAWeek(t *testing.T) {
	asked := map[string]bool{}
	e, k := keeperEnv(t, func(ctx context.Context, artist, title string) ([]coverfind.Candidate, error) {
		asked[title] = true
		return nil, nil
	})
	e.addSong(t, "old", "o/o.mp3", "x")
	e.addSong(t, "fresh", "f/f.mp3", "x")
	if err := e.s.db.SetCoverMarker("old", "none@2026-09-10"); err != nil {
		t.Fatal(err)
	}
	if err := e.s.db.SetCoverMarker("fresh", "none@2026-09-18"); err != nil {
		t.Fatal(err)
	}
	if err := k.pass(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !asked["Title old"] || asked["Title fresh"] {
		t.Errorf("искали: %v — ждали только old", asked)
	}
	if got := coverMarker(t, e.s, "old"); got != "none@2026-09-20" {
		t.Errorf("метка old: %q", got)
	}
	if got := coverMarker(t, e.s, "fresh"); got != "none@2026-09-18" {
		t.Errorf("метка fresh не должна меняться: %q", got)
	}
}

// Kick: на nil не падает, лишние стуки не блокируют; фоновый цикл после стука запускает круг.
func TestCoverKeeperKickRunsPass(t *testing.T) {
	var nilKeeper *coverKeeper
	nilKeeper.Kick()
	nilKeeper.Stop()

	asked := make(chan string, 4)
	e, k := keeperEnv(t, func(ctx context.Context, artist, title string) ([]coverfind.Candidate, error) {
		asked <- title
		return nil, nil
	})
	k.delay = time.Hour
	k.every = time.Hour
	k.settle = time.Millisecond
	e.addSong(t, "n", "n/n.mp3", "x")
	k.Start()
	defer k.Stop()
	for i := 0; i < 5; i++ {
		k.Kick() // лишние сливаются
	}
	select {
	case got := <-asked:
		if got != "Title n" {
			t.Errorf("искали %q", got)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("после Kick круг не запустился")
	}
}
