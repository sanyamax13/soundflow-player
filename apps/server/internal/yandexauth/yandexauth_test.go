package yandexauth

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFlow(t *testing.T) {
	polls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		switch r.URL.Path {
		case "/device/code":
			_, _ = w.Write([]byte(`{"device_code":"dc","user_code":"ABCD1234","verification_url":"https://ya.ru/device","interval":5,"expires_in":300}`))
		case "/token":
			polls++
			if r.Form.Get("code") != "dc" || r.Form.Get("grant_type") != "device_code" {
				w.WriteHeader(400)
				_, _ = w.Write([]byte(`{"error":"bad_verification_code"}`))
				return
			}
			if polls == 1 {
				w.WriteHeader(400)
				_, _ = w.Write([]byte(`{"error":"authorization_pending"}`))
				return
			}
			_, _ = w.Write([]byte(`{"access_token":"tok","token_type":"bearer"}`))
		}
	}))
	defer srv.Close()
	BaseURL = srv.URL
	c, err := Start(context.Background(), "dev123", "SoundFlow")
	if err != nil || c.UserCode != "ABCD1234" {
		t.Fatalf("Start: %+v %v", c, err)
	}
	if _, err := Poll(context.Background(), c.DeviceCode); !errors.Is(err, ErrPending) {
		t.Fatalf("первый опрос должен ждать, а: %v", err)
	}
	tok, err := Poll(context.Background(), c.DeviceCode)
	if err != nil || tok != "tok" {
		t.Fatalf("токен: %q %v", tok, err)
	}
}
