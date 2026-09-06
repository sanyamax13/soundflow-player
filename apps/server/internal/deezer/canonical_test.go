package deezer

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

const creepJSON = `{"data":[
  {"title":"Creep","title_version":"","duration":238,"artist":{"name":"Radiohead"},"album":{"title":"Pablo Honey"}},
  {"title":"Creep (Acoustic)","title_version":"(Acoustic)","duration":258,"artist":{"name":"Radiohead"},"album":{"title":"Creep EP"}},
  {"title":"Creep (Cover of Radiohead)","title_version":"(Cover of Radiohead)","duration":236,"artist":{"name":"Glee Cast"},"album":{"title":"Glee"}}
]}`

func withServer(t *testing.T, body string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	old := baseURL
	baseURL = srv.URL
	t.Cleanup(func() { baseURL = old })
}

func TestCanonicalTrackPicksStudio(t *testing.T) {
	withServer(t, creepJSON)
	got, err := CanonicalTrack(context.Background(), "Radiohead", "Creep")
	if err != nil {
		t.Fatalf("CanonicalTrack: %v", err)
	}
	if !got.Found || got.DurationSec != 238 || got.Title != "Creep" {
		t.Errorf("ждал студийную Creep 238с, получил %+v", got)
	}
}

func TestCanonicalTrackSkipsCoverArtist(t *testing.T) {
	// Только кавер другого исполнителя и акустика — чистой версии нужного нет.
	body := `{"data":[
      {"title":"Creep (Acoustic)","title_version":"(Acoustic)","duration":258,"artist":{"name":"Radiohead"},"album":{"title":"Creep EP"}},
      {"title":"Creep","title_version":"","duration":236,"artist":{"name":"Glee Cast"},"album":{"title":"Glee"}}
    ]}`
	withServer(t, body)
	got, err := CanonicalTrack(context.Background(), "Radiohead", "Creep")
	if err != nil {
		t.Fatalf("CanonicalTrack: %v", err)
	}
	if got.Found {
		t.Errorf("ждал Found=false (нет чистой версии Radiohead), получил %+v", got)
	}
}

func TestCanonicalTrackThrottleNotError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()
	old := baseURL
	baseURL = srv.URL
	defer func() { baseURL = old }()

	got, err := CanonicalTrack(context.Background(), "a", "b")
	if err != nil {
		t.Fatalf("троттлинг не должен быть ошибкой: %v", err)
	}
	if got.Found {
		t.Errorf("ждал Found=false при не-200, получил %+v", got)
	}
}
