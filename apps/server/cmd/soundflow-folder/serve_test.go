package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTracksAndFile(t *testing.T) {
	dir := t.TempDir()
	mp3 := filepath.Join(dir, "Кто-то — Песня.mp3")
	if err := os.WriteFile(mp3, []byte("ID3fakebytes-not-real-audio"), 0o644); err != nil {
		t.Fatal(err)
	}

	items, err := Scan(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("ждал 1 песню, получил %d", len(items))
	}
	// тегов нет — имя из файла, исполнитель из папки
	if items[0].Title == "" || items[0].Artist == "" {
		t.Fatalf("пустые название/исполнитель: %+v", items[0])
	}
	if items[0].MimeType != "audio/mpeg" || items[0].Format != "MP3" {
		t.Fatalf("формат не MP3: %+v", items[0])
	}

	s := NewServer()
	s.SetItems(items)
	h := s.Handler()

	// /v1/tracks
	rr := do(h, "GET", "/v1/tracks", "")
	if rr.Code != 200 {
		t.Fatalf("/v1/tracks код %d", rr.Code)
	}
	var got struct {
		Tracks []map[string]any `json:"tracks"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Tracks) != 1 {
		t.Fatalf("в ответе %d треков", len(got.Tracks))
	}
	id, _ := got.Tracks[0]["id"].(string)
	if !strings.HasPrefix(id, "f_") {
		t.Fatalf("странный id: %q", id)
	}

	// файл
	rr = do(h, "GET", "/v1/music/"+id+"/file", "")
	if rr.Code != 200 || rr.Body.Len() == 0 {
		t.Fatalf("файл не отдался: код %d, %d байт", rr.Code, rr.Body.Len())
	}

	// заглушка обложки (в файле картинки нет) — всё равно PNG
	rr = do(h, "GET", "/v1/cover/"+id, "")
	if rr.Code != 200 || rr.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("обложка-заглушка: код %d, тип %q", rr.Code, rr.Header().Get("Content-Type"))
	}

	// health
	if do(h, "GET", "/v1/health", "").Code != 200 {
		t.Fatal("/v1/health не 200")
	}

	// next-batch с пустым exclude — вернёт наш трек
	rr = do(h, "POST", "/v1/library/next-batch", `{"exclude_ids":[],"budget_bytes":999999999}`)
	if rr.Code != 200 {
		t.Fatalf("next-batch код %d", rr.Code)
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Tracks) != 1 {
		t.Fatalf("next-batch вернул %d", len(got.Tracks))
	}

	// sync/events — принимает и не падает
	rr = do(h, "POST", "/v1/sync/events", `{"events":[{"kind":"play"}]}`)
	if rr.Code != 200 {
		t.Fatalf("sync/events код %d", rr.Code)
	}
}

func TestCleanBrokenNames(t *testing.T) {
	cases := map[string]string{
		"  Баста  ":                 "Баста",
		"???? ????????, ??????? ??": "",
		"????? (BTS_":               "",
		"":                          "",
		"AC/DC":                     "AC/DC",
	}
	for in, want := range cases {
		if got := clean(in); got != want {
			t.Errorf("clean(%q) = %q, ждал %q", in, got, want)
		}
	}
}

func do(h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
	}
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, r)
	return rr
}
