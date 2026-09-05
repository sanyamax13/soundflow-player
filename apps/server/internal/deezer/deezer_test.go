package deezer

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCoverFound(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"data":[{"album":{"cover_xl":"https://x/1000x1000-000000-80-0-0.jpg"}}]}`))
	}))
	defer srv.Close()
	old := baseURL
	baseURL = srv.URL
	defer func() { baseURL = old }()

	url, err := Cover(context.Background(), "Dr. Dre", "What's The Difference")
	if err != nil {
		t.Fatalf("Cover: %v", err)
	}
	if url != "https://x/1000x1000-000000-80-0-0.jpg" {
		t.Errorf("ждал ссылку на обложку, получил %q", url)
	}
}

func TestCoverNotFound(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"data":[]}`))
	}))
	defer srv.Close()
	old := baseURL
	baseURL = srv.URL
	defer func() { baseURL = old }()

	url, err := Cover(context.Background(), "Совсем Неизвестный", "Артист")
	if err != nil {
		t.Fatalf("Cover: %v", err)
	}
	if url != "" {
		t.Errorf("ждал пустую ссылку, получил %q", url)
	}
}

func TestCoverHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()
	old := baseURL
	baseURL = srv.URL
	defer func() { baseURL = old }()

	url, err := Cover(context.Background(), "a", "b")
	if err != nil {
		t.Fatalf("троттлинг не должен считаться ошибкой: %v", err)
	}
	if url != "" {
		t.Errorf("ждал пустую ссылку при не-200, получил %q", url)
	}
}
