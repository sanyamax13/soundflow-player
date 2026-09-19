package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Песня «на сервере Яндекса»: 1000 байт, отдаётся с поддержкой Range.
func fakeYandexAudio(t *testing.T, status *atomic.Int32) (*httptest.Server, []byte) {
	t.Helper()
	data := make([]byte, 1000)
	for i := range data {
		data[i] = byte(i % 251)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if status != nil && status.Load() != 0 {
			http.Error(w, "протухла", int(status.Load()))
			return
		}
		w.Header().Set("Content-Type", "audio/mpeg")
		http.ServeContent(w, r, "x.mp3", time.Time{}, bytes.NewReader(data))
	}))
	t.Cleanup(srv.Close)
	return srv, data
}

// Качалка: на /yandex/stream-url отдаёт ссылку, считает обращения.
func fakeStreamSidecar(t *testing.T, urlFn func(call int32) string) *atomic.Int32 {
	t.Helper()
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/yandex/stream-url" {
			http.NotFound(w, r)
			return
		}
		n := calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		u := urlFn(n)
		if u == "" {
			_, _ = w.Write([]byte(`{"url":null,"error":"не нашла в Яндексе"}`))
			return
		}
		_, _ = w.Write([]byte(`{"url":"` + u + `","bitrate_kbps":192}`))
	}))
	t.Cleanup(srv.Close)
	t.Setenv("SOUNDFLOW_SIDECAR_URL", srv.URL)
	return &calls
}

func previewGET(s *Service, query, rng string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("GET", "/api/yandex/preview?"+query, nil)
	if rng != "" {
		req.Header.Set("Range", rng)
	}
	rec := httptest.NewRecorder()
	s.hYandexPreview(rec, req)
	return rec
}

func resetPreviewCache() {
	previewMu.Lock()
	previewCache = map[string]previewEntry{}
	previewMu.Unlock()
}

func TestPreviewStreamsWholeSongAndCachesLink(t *testing.T) {
	resetPreviewCache()
	up, data := fakeYandexAudio(t, nil)
	calls := fakeStreamSidecar(t, func(int32) string { return up.URL })
	s := &Service{}

	rec := previewGET(s, "id=42&artist=A&title=B", "")
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), data) {
		t.Fatalf("целиком: код %d, %d байт", rec.Code, rec.Body.Len())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "audio/mpeg" {
		t.Errorf("Content-Type = %q", ct)
	}
	if rec.Header().Get("Accept-Ranges") == "" {
		t.Error("нет Accept-Ranges — плеер не сможет перематывать")
	}
	// второй запрос идёт по запомненной ссылке — качалку не дёргаем
	if rec2 := previewGET(s, "id=42&artist=A&title=B", ""); rec2.Code != 200 {
		t.Fatalf("второй запрос: %d", rec2.Code)
	}
	if calls.Load() != 1 {
		t.Errorf("качалку спросили %d раз, ждал 1 (ссылка должна запоминаться)", calls.Load())
	}
}

func TestPreviewRangeRequest(t *testing.T) {
	resetPreviewCache()
	up, data := fakeYandexAudio(t, nil)
	fakeStreamSidecar(t, func(int32) string { return up.URL })
	rec := previewGET(&Service{}, "id=7", "bytes=100-199")
	if rec.Code != http.StatusPartialContent {
		t.Fatalf("ждал 206, получил %d", rec.Code)
	}
	if !bytes.Equal(rec.Body.Bytes(), data[100:200]) {
		t.Error("кусок не тот")
	}
	if cr := rec.Header().Get("Content-Range"); cr != "bytes 100-199/1000" {
		t.Errorf("Content-Range = %q", cr)
	}
	if cl := rec.Header().Get("Content-Length"); cl != strconv.Itoa(100) {
		t.Errorf("Content-Length = %q", cl)
	}
}

// Ссылка протухла (Яндекс отвечает 403) — берём новую у качалки и отдаём песню.
func TestPreviewRefreshesExpiredLink(t *testing.T) {
	resetPreviewCache()
	var deadStatus atomic.Int32
	deadStatus.Store(403)
	dead, _ := fakeYandexAudio(t, &deadStatus)
	live, data := fakeYandexAudio(t, nil)
	calls := fakeStreamSidecar(t, func(n int32) string {
		if n == 1 {
			return dead.URL
		}
		return live.URL
	})
	rec := previewGET(&Service{}, "id=9", "")
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), data) {
		t.Fatalf("после протухшей ссылки: код %d, %d байт", rec.Code, rec.Body.Len())
	}
	if calls.Load() != 2 {
		t.Errorf("качалку спросили %d раз, ждал 2", calls.Load())
	}
}

func TestPreviewErrors(t *testing.T) {
	resetPreviewCache()
	s := &Service{}

	t.Setenv("SOUNDFLOW_SIDECAR_URL", "")
	if rec := previewGET(s, "id=1", ""); rec.Code != 503 || !strings.Contains(rec.Body.String(), "качалка") {
		t.Errorf("нет качалки: ждал 503 с пояснением, получил %d %q", rec.Code, rec.Body)
	}
	if rec := previewGET(s, "", ""); rec.Code != 400 {
		t.Errorf("без параметров: ждал 400, получил %d", rec.Code)
	}
	if rec := previewGET(s, "artist=A", ""); rec.Code != 400 {
		t.Errorf("только artist: ждал 400, получил %d", rec.Code)
	}

	fakeStreamSidecar(t, func(int32) string { return "" })
	rec := previewGET(s, "artist=A&title=B", "")
	if rec.Code != 502 || !strings.Contains(rec.Body.String(), "не нашла") {
		t.Errorf("качалка не нашла песню: ждал 502 с причиной, получил %d %q", rec.Code, rec.Body)
	}

	resetPreviewCache()
	fakeStreamSidecar(t, func(int32) string { return "file:///etc/passwd" })
	if rec := previewGET(s, "id=5", ""); rec.Code != 502 {
		t.Errorf("странная ссылка не http(s): ждал 502, получил %d", rec.Code)
	}
}

// Ручка слушания — только с этого компьютера (иначе Яндекс по токену Alex слушала бы вся сеть).
func TestPreviewIsLocalOnly(t *testing.T) {
	req := httptest.NewRequest("GET", "/api/yandex/preview?id=1", nil)
	req.RemoteAddr = "192.168.1.50:5555"
	rec := httptest.NewRecorder()
	localOnly((&Service{}).hYandexPreview)(rec, req)
	if rec.Code != 403 {
		t.Fatalf("ждал 403, получил %d", rec.Code)
	}
	_ = io.Discard
}
