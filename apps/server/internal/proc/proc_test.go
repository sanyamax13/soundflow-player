package proc

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveFFmpeg(t *testing.T) {
	dir := t.TempDir()

	// ничего нет — просто "ffmpeg" из PATH
	if got := resolveFFmpeg("", dir); got != "ffmpeg" {
		t.Errorf("пустая папка: %q", got)
	}
	// ffmpeg.exe рядом с программой — берём его
	exe := filepath.Join(dir, "ffmpeg.exe")
	if err := os.WriteFile(exe, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := resolveFFmpeg("", dir); got != exe {
		t.Errorf("рядом с программой: %q, ждал %q", got, exe)
	}
	// переменная окружения главнее
	if got := resolveFFmpeg(`D:\tools\ffmpeg.exe`, dir); got != `D:\tools\ffmpeg.exe` {
		t.Errorf("SOUNDFLOW_FFMPEG: %q", got)
	}
	// папка с именем ffmpeg.exe не считается
	dir2 := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir2, "ffmpeg.exe"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := resolveFFmpeg("", dir2); got != "ffmpeg" {
		t.Errorf("папка вместо файла: %q", got)
	}
}
