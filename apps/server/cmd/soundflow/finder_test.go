package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"

	"soundflow/server/internal/sidecar"
)

// findSidecar — сайдкар, записывающий, какие источники ему велели пропустить в каждом запросе
// /find-audio, и отвечающий по очереди заранее заготовленными ответами.
type findSidecar struct {
	mu      sync.Mutex
	skips   [][]string
	answers []string // JSON-ответы по порядку запросов
	status  int      // 0 → 200
	srv     *httptest.Server
}

func newFindSidecar(t *testing.T, answers ...string) *findSidecar {
	t.Helper()
	f := &findSidecar{answers: answers}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Skip []string `json:"skip_providers"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		n := len(f.skips)
		f.skips = append(f.skips, body.Skip)
		f.mu.Unlock()
		if f.status != 0 {
			http.Error(w, "сломано", f.status)
			return
		}
		ans := `{"found":false}`
		if n < len(f.answers) {
			ans = f.answers[n]
		}
		_, _ = w.Write([]byte(ans))
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *findSidecar) requests() [][]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([][]string(nil), f.skips...)
}

func has(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func sorted(list []string) []string {
	out := append([]string(nil), list...)
	sort.Strings(out)
	return out
}

const foundYandex = `{"found":true,"file_path":"G:/y.mp3","bitrate_kbps":320,"source":"yandex"}`
const foundTorrent = `{"found":true,"file_path":"E:/t.mp3","bitrate_kbps":320,"source":"nnmclub_album"}`

// Яндекс нашёл — торренты не трогаем и qBittorrent не включаем.
func TestFindAudioYandexHitSkipsTorrents(t *testing.T) {
	sc := newFindSidecar(t, foundYandex)
	started := 0
	f := &localFinder{Client: sidecar.New(sc.srv.URL), startTorrents: func() error { started++; return nil }}

	res, err := f.FindAudio(context.Background(), "Кино", "Группа крови", 0, []string{"musify"})
	if err != nil || !res.Found || res.Source != "yandex" {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	reqs := sc.requests()
	if len(reqs) != 1 {
		t.Fatalf("запросов к сайдкару %d, ждал 1", len(reqs))
	}
	for _, p := range append([]string{"musify"}, torrentProviders...) {
		if !has(reqs[0], p) {
			t.Errorf("в первом заходе не пропущен %q: %v", p, reqs[0])
		}
	}
	if started != 0 {
		t.Errorf("qBittorrent включили без нужды (%d раз)", started)
	}
}

// Яндекс не нашёл — включаем qBittorrent и вторым заходом идём только в торренты.
func TestFindAudioFallsBackToTorrents(t *testing.T) {
	sc := newFindSidecar(t, `{"found":false}`, foundTorrent)
	started := 0
	f := &localFinder{Client: sidecar.New(sc.srv.URL), startTorrents: func() error { started++; return nil }}

	res, err := f.FindAudio(context.Background(), "Placebo", "Special K", 0, []string{"musify", "soulseek"})
	if err != nil || !res.Found || res.Source != "nnmclub_album" {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	if started != 1 {
		t.Fatalf("qBittorrent включили %d раз, ждал 1", started)
	}
	reqs := sc.requests()
	if len(reqs) != 2 {
		t.Fatalf("запросов %d, ждал 2", len(reqs))
	}
	second := reqs[1]
	if !has(second, "yandex") {
		t.Errorf("во втором заходе Яндекс не пропущен: %v", second)
	}
	for _, p := range torrentProviders {
		if has(second, p) {
			t.Errorf("во втором заходе торрент %q пропущен, а должен искаться: %v", p, second)
		}
	}
	for _, p := range []string{"musify", "soulseek"} {
		if !has(second, p) {
			t.Errorf("пожелание вызывающего %q потерялось: %v", p, second)
		}
	}
}

// qBittorrent не включился — для вызывающего это просто «не найдено», без ошибки и без второго запроса.
func TestFindAudioTorrentsUnavailableIsNotFound(t *testing.T) {
	sc := newFindSidecar(t, `{"found":false}`)
	f := &localFinder{Client: sidecar.New(sc.srv.URL), startTorrents: func() error { return errors.New("qBittorrent не найден") }}

	res, err := f.FindAudio(context.Background(), "Placebo", "Special K", 0, nil)
	if err != nil || res.Found {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	if n := len(sc.requests()); n != 1 {
		t.Errorf("запросов %d, ждал 1 (без торрент-захода)", n)
	}
}

// Вызывающий сам выключил все торренты — второго захода нет, qBittorrent не трогаем.
func TestFindAudioAllTorrentsSkippedByCaller(t *testing.T) {
	sc := newFindSidecar(t, `{"found":false}`)
	started := 0
	f := &localFinder{Client: sidecar.New(sc.srv.URL), startTorrents: func() error { started++; return nil }}

	res, err := f.FindAudio(context.Background(), "x", "y", 0, torrentProviders)
	if err != nil || res.Found {
		t.Fatalf("res=%+v err=%v", res, err)
	}
	if started != 0 || len(sc.requests()) != 1 {
		t.Errorf("started=%d запросов=%d", started, len(sc.requests()))
	}
}

// Один торрент вызывающий отключил — он остаётся отключённым и во втором заходе.
func TestFindAudioKeepsCallerTorrentSkip(t *testing.T) {
	sc := newFindSidecar(t, `{"found":false}`, `{"found":false}`)
	f := &localFinder{Client: sidecar.New(sc.srv.URL), startTorrents: func() error { return nil }}

	if _, err := f.FindAudio(context.Background(), "x", "y", 0, []string{"rutor"}); err != nil {
		t.Fatal(err)
	}
	reqs := sc.requests()
	if len(reqs) != 2 {
		t.Fatalf("запросов %d, ждал 2", len(reqs))
	}
	if !has(reqs[1], "rutor") || has(reqs[1], "nnmclub") || has(reqs[1], "tapochek") {
		t.Errorf("второй заход: %v", sorted(reqs[1]))
	}
}

// Сайдкар упал на первом заходе — это ошибка, торренты не запускаем.
func TestFindAudioSidecarErrorStopsEverything(t *testing.T) {
	sc := newFindSidecar(t)
	sc.status = 500
	started := 0
	f := &localFinder{Client: sidecar.New(sc.srv.URL), startTorrents: func() error { started++; return nil }}

	if _, err := f.FindAudio(context.Background(), "x", "y", 0, nil); err == nil {
		t.Fatal("ждал ошибку сайдкара")
	}
	if started != 0 {
		t.Errorf("qBittorrent включили после падения сайдкара")
	}
}

func TestWithSkippedDoesNotTouchInputOrDuplicate(t *testing.T) {
	in := []string{"a", "yandex"}
	out := withSkipped(in, "yandex", "b")
	if strings.Join(in, ",") != "a,yandex" {
		t.Errorf("исходный срез изменён: %v", in)
	}
	if strings.Join(out, ",") != "a,yandex,b" {
		t.Errorf("out=%v", out)
	}
}

// qBittorrent запускается без заставки (окно потом сворачивает qbtwindow_windows.go).
func TestQbtLaunchCmdNoSplash(t *testing.T) {
	const exe = `C:\Program Files\qBittorrent\qbittorrent.exe`
	cmd := qbtLaunchCmd(exe)
	want := []string{exe, "--no-splash"}
	if strings.Join(cmd.Args, "|") != strings.Join(want, "|") {
		t.Errorf("команда: %v", cmd.Args)
	}
}
