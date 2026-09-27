package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// Окно «только плеер» на другом ПК пускают к командам «только с этого компьютера» лишь с верным секретом;
// без секрета на сервере режим выключен.
func TestLocalOnlyTrustedWindowToken(t *testing.T) {
	h := localOnly(func(w http.ResponseWriter, r *http.Request) {})
	cases := []struct {
		name, serverToken, sent string
		want                    int
	}{
		{"верный секрет", "s3cret", "s3cret", http.StatusOK},
		{"чужой секрет", "s3cret", "guess", http.StatusForbidden},
		{"без секрета", "s3cret", "", http.StatusForbidden},
		{"режим выключен на сервере", "", "s3cret", http.StatusForbidden},
	}
	for _, c := range cases {
		t.Setenv("SOUNDFLOW_WINDOW_TOKEN", c.serverToken)
		req := httptest.NewRequest("POST", "/api/tracks/delete-forever", nil)
		req.RemoteAddr = "192.168.1.104:50000"
		if c.sent != "" {
			req.Header.Set(windowTokenHeader, c.sent)
		}
		rec := httptest.NewRecorder()
		h(rec, req)
		if rec.Code != c.want {
			t.Errorf("%s: код %d, ждали %d", c.name, rec.Code, c.want)
		}
	}
}

// Прокси окна кладёт свой секрет и не пропускает подставленный снаружи.
func TestRemoteProxyAddsWindowToken(t *testing.T) {
	var got, host string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get(windowTokenHeader)
		host = r.URL.Path
	}))
	defer srv.Close()
	t.Setenv("SOUNDFLOW_WINDOW_TOKEN", "mine")
	p, err := remoteProxy(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("GET", "/api/info", nil)
	req.Header.Set(windowTokenHeader, "forged")
	p.ServeHTTP(httptest.NewRecorder(), req)
	if got != "mine" || host != "/api/info" {
		t.Errorf("сервер получил секрет %q по пути %q, ждали mine и /api/info", got, host)
	}
}

// Без переменных окружения адрес сервера и секрет берутся из player.json рядом с программой.
func TestLoadPlayerConfig(t *testing.T) {
	dir := t.TempDir()
	if c := loadPlayerConfig(dir); c.Server != "" || c.Token != "" {
		t.Fatalf("без файла настройки должны быть пустыми: %+v", c)
	}
	if err := os.WriteFile(filepath.Join(dir, playerConfigName), []byte(`{"server":"http://192.168.1.73:8090/","token":"abc"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	c := loadPlayerConfig(dir)
	if c.Server != "http://192.168.1.73:8090/" || c.Token != "abc" {
		t.Errorf("прочитали %+v", c)
	}
}
