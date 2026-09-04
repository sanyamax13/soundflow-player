package sidecar

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFindAudioRequestAndParse(t *testing.T) {
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/find-audio" || r.Method != http.MethodPost {
			t.Errorf("неожиданный запрос %s %s", r.Method, r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"found":true,"file_path":"E:\\soundflow-data\\cache\\A - B.mp3","bitrate_kbps":320,"duration_sec":222,"size_bytes":9000000,"source":"yandex","provider_url":"yandexmusic://1"}`))
	}))
	defer srv.Close()

	c := New(srv.URL)
	res, err := c.FindAudio(context.Background(), "Кино", "Группа крови", 220, []string{"soundcloud", "youtube_music", "soulseek"})
	if err != nil {
		t.Fatalf("FindAudio: %v", err)
	}
	if !res.Found || res.BitrateKbps != 320 || res.Source != "yandex" {
		t.Fatalf("ответ разобран неверно: %+v", res)
	}
	if gotBody["artist"] != "Кино" || gotBody["title"] != "Группа крови" {
		t.Errorf("тело запроса неверное: %v", gotBody)
	}
	if gotBody["expected_duration_sec"].(float64) != 220 {
		t.Errorf("expected_duration_sec не передан: %v", gotBody["expected_duration_sec"])
	}
	skip, _ := gotBody["skip_providers"].([]any)
	if len(skip) != 3 {
		t.Errorf("skip_providers не передан: %v", gotBody["skip_providers"])
	}
}

func TestFindAudioNotFound(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"found":false}`))
	}))
	defer srv.Close()
	res, err := New(srv.URL).FindAudio(context.Background(), "x", "y", 0, nil)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.Found {
		t.Fatal("ждал found=false")
	}
}

func TestServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte(`resolve failed`))
	}))
	defer srv.Close()
	_, err := New(srv.URL).FindAudio(context.Background(), "x", "y", 0, nil)
	if err == nil {
		t.Fatal("ждал ошибку на 502")
	}
}

func TestYandexTrackCover(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/yandex/track-cover" {
			t.Errorf("путь %s", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"found":true,"cover_url":"https://avatars.yandex.net/x/600x600"}`))
	}))
	defer srv.Close()
	url, err := New(srv.URL).YandexTrackCover(context.Background(), "a", "b")
	if err != nil || url == "" {
		t.Fatalf("cover: %q %v", url, err)
	}
}
