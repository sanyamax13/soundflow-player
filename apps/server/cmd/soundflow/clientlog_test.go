package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClientLogWritesNextToDB(t *testing.T) {
	e := ctxFixture(t)
	if rec := postJSON(e.s.hClientLog, `{"what":"canplay   t=0.0\nrs=4"}`); rec.Code != 200 {
		t.Fatalf("client-log: %d %s", rec.Code, rec.Body)
	}
	b, err := os.ReadFile(filepath.Join(filepath.Dir(e.s.dbPath), clientLogFile))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(string(b), "  canplay t=0.0 rs=4\n") {
		t.Errorf("запись не такая: %q", b)
	}
	// длинная запись обрезается, пустая и не-JSON отбиваются
	long := strings.Repeat("я", clientLogLine+100)
	if rec := postJSON(e.s.hClientLog, `{"what":"`+long+`"}`); rec.Code != 200 {
		t.Fatalf("длинная: %d", rec.Code)
	}
	b, _ = os.ReadFile(filepath.Join(filepath.Dir(e.s.dbPath), clientLogFile))
	last := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if got := strings.TrimSpace(last[len(last)-1][len("2006-01-02 15:04:05.000"):]); len([]rune(got)) != clientLogLine {
		t.Errorf("длинную запись не обрезали до %d: %d", clientLogLine, len([]rune(got)))
	}
	for _, bad := range []string{`не json`, `{}`, `{"what":"  "}`} {
		if rec := postJSON(e.s.hClientLog, bad); rec.Code != 400 {
			t.Errorf("%q: ждал 400, получил %d", bad, rec.Code)
		}
	}
}

func TestClientLogRotates(t *testing.T) {
	path := filepath.Join(t.TempDir(), clientLogFile)
	if err := os.WriteFile(path, []byte(strings.Repeat("x", clientLogMax+1)), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := appendClientLog(path, "новая"); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(path + ".old"); err != nil || st.Size() != clientLogMax+1 {
		t.Errorf("старый файл не отложен: %v", err)
	}
	if b, _ := os.ReadFile(path); !strings.HasSuffix(string(b), "  новая\n") || len(b) > 100 {
		t.Errorf("новый файл не с чистого листа: %q", b)
	}
}

// Окно узнаёт из /api/info настоящий адрес программы «изнутри» компьютера — по нему играет звук.
func TestLocalURLFollowsBoundPort(t *testing.T) {
	e := ctxFixture(t)
	e.s.phoneAddr = ":8091"
	if got := e.s.localURL(); got != "http://127.0.0.1:8091" {
		t.Errorf("до привязки порта: %s", got)
	}
	e.s.phoneBoundAddr = "0.0.0.0:8093" // 8091 занят — встали на следующий
	if got := e.s.localURL(); got != "http://127.0.0.1:8093" {
		t.Errorf("после отката порта: %s", got)
	}
	rec := httptest.NewRecorder()
	e.s.hInfo(rec, httptest.NewRequest("GET", "/api/info", nil))
	var info struct {
		LocalURL string `json:"local_url"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil || info.LocalURL != "http://127.0.0.1:8093" {
		t.Errorf("/api/info: local_url=%q err=%v", info.LocalURL, err)
	}
}
