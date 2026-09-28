package appsettings

import (
	"crypto/pbkdf2"
	"crypto/sha512"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestQbtPasswordHashVerifies(t *testing.T) {
	h, err := QbtPasswordHash("secret")
	if err != nil {
		t.Fatal(err)
	}
	in := strings.TrimSuffix(strings.TrimPrefix(h, `"@ByteArray(`), `)"`)
	saltB, keyB, ok := strings.Cut(in, ":")
	if !ok {
		t.Fatalf("формат: %s", h)
	}
	salt, _ := base64.StdEncoding.DecodeString(saltB)
	key, _ := base64.StdEncoding.DecodeString(keyB)
	again, _ := pbkdf2.Key(sha512.New, "secret", salt, 100000, 64)
	if string(again) != string(key) || len(salt) != 16 {
		t.Fatal("хеш не сходится")
	}
}

func TestWriteQbtWebUIKeepsOtherSettings(t *testing.T) {
	ini := filepath.Join(t.TempDir(), "qBittorrent.ini")
	old := "[Preferences]\r\nDownloads\\SavePath=D:/t\r\nWebUI\\Port=9090\r\n\r\n[Other]\r\nx=1\r\n"
	_ = os.WriteFile(ini, []byte(old), 0o644)
	if err := WriteQbtWebUI(ini, "sf", "p"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(ini)
	s := string(b)
	for _, want := range []string{`Downloads\SavePath=D:/t`, `WebUI\Port=8080`, `WebUI\Username=sf`, `WebUI\Enabled=true`, "[Other]\r\nx=1", "[LegalNotice]\r\nAccepted=true"} {
		if !strings.Contains(s, want) {
			t.Errorf("нет %q в\n%s", want, s)
		}
	}
	if strings.Contains(s, "9090") {
		t.Error("старый порт остался")
	}
	if i, j := strings.Index(s, "WebUI\\Username"), strings.Index(s, "[Other]"); i > j {
		t.Error("новый ключ записан не в свою секцию")
	}
}

func TestSaveRoundTrip(t *testing.T) {
	dir := t.TempDir()
	if Exists(dir) {
		t.Fatal("файла ещё нет")
	}
	if err := Save(dir, Settings{MusicDir: `D:\M`, QbtUser: "sf"}); err != nil {
		t.Fatal(err)
	}
	s, ok := Load(dir)
	if !ok || s.MusicDir != `D:\M` || s.QbtUser != "sf" || !Exists(dir) {
		t.Fatalf("не сохранилось: %+v", s)
	}
}
