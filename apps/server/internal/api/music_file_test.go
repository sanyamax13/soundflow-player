package api

import (
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/go-chi/chi/v5"

	"soundflow/server/internal/music"
)

func musicFileServer(t *testing.T) (http.Handler, string) {
	t.Helper()
	st, pm, trackID, _, _ := gateFixture(t)
	s := &Server{DB: st, PathMap: pm, Music: music.New("")}
	r := chi.NewRouter()
	r.Get("/v1/music/{id}/file", s.musicFile)
	return r, trackID
}

func getFile(h http.Handler, id string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/v1/music/"+id+"/file", nil))
	return rec
}

// Настоящий трек — отдаётся его файл.
func TestMusicFileServesCatalogTrack(t *testing.T) {
	h, id := musicFileServer(t)
	rec := getFile(h, id)
	if rec.Code != http.StatusOK || rec.Body.String() != "audio-bytes" {
		t.Fatalf("ждал 200 и содержимое файла, получил %d %q", rec.Code, rec.Body.String())
	}
}

// Каталожный id без файла — 404, а не тестовый писк (19.09.2026: телефон
// «скачивал» писк вместо песни у пустой записи-двойника).
func TestMusicFileMissingCatalogTrackIs404(t *testing.T) {
	h, _ := musicFileServer(t)
	if rec := getFile(h, "t_no_such_track"); rec.Code != http.StatusNotFound {
		t.Fatalf("ждал 404, получил %d (%d байт)", rec.Code, rec.Body.Len())
	}
}

// Трек в каталоге, но файл с диска пропал — тоже не писк.
func TestMusicFileDeletedFileIsNotATone(t *testing.T) {
	st, pm, trackID, local, _ := gateFixture(t)
	if err := os.Remove(local); err != nil {
		t.Fatal(err)
	}
	s := &Server{DB: st, PathMap: pm, Music: music.New("")}
	r := chi.NewRouter()
	r.Get("/v1/music/{id}/file", s.musicFile)
	rec := getFile(r, trackID)
	if rec.Code == http.StatusOK && rec.Header().Get("Content-Type") == "audio/wav" {
		t.Fatalf("вместо песни отдан тестовый тон (%d байт)", rec.Body.Len())
	}
}

// Демо-режим не сломан: тестовые тоны по-прежнему отдаются.
func TestMusicFileDemoToneStillWorks(t *testing.T) {
	h, _ := musicFileServer(t)
	rec := getFile(h, "test-tone")
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "audio/wav" {
		t.Fatalf("ждал WAV-тон, получил %d %q", rec.Code, rec.Header().Get("Content-Type"))
	}
}
