package appsettings

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEnvFromFile(t *testing.T) {
	dir := t.TempDir()
	js := `{"musicDir":"D:\\Music","yandexToken":"tok","relay":{"host":"1.2.3.4:22","user":"sf","secret":"s","publicUrl":"https://x/sf/"}}`
	if err := os.WriteFile(filepath.Join(dir, FileName), []byte(js), 0o644); err != nil {
		t.Fatal(err)
	}
	s, ok := Load(dir)
	if !ok {
		t.Fatal("не прочитался")
	}
	m := Env(s, dir)
	want := map[string]string{
		"SOUNDFLOW_ALBUMS_ARTIST_ROOT": `D:\Music`,
		"SOUNDFLOW_ALBUMS_DIR":         filepath.Join(`D:\Music`, "Торренты"),
		"SOUNDFLOW_TRACK_CACHE_DIR":    filepath.Join(`D:\Music`, "Яндекс"),
		"YANDEX_MUSIC_TOKEN":           "tok",
		"SOUNDFLOW_RELAY_HOST":         "1.2.3.4:22",
		"SOUNDFLOW_RELAY_REMOTE_BIND":  "127.0.0.1:8093",
		"SOUNDFLOW_RELAY_KEY_FILE":     filepath.Join(dir, "relay_key"),
	}
	for k, v := range want {
		if m[k] != v {
			t.Errorf("%s = %q, ждали %q", k, m[k], v)
		}
	}
	if _, set := m["SOUNDFLOW_ADDR"]; set {
		t.Error("пустой addr не должен задавать переменную")
	}
}

func TestApplyEnvWins(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, FileName), []byte(`{"yandexToken":"file"}`), 0o644)
	t.Setenv("YANDEX_MUSIC_TOKEN", "env")
	Apply(dir)
	if got := os.Getenv("YANDEX_MUSIC_TOKEN"); got != "env" {
		t.Fatalf("окружение должно быть главнее файла, получили %q", got)
	}
}

func TestApplyNoFile(t *testing.T) {
	Apply(t.TempDir()) // нет файла — ничего не делает и не падает
}
