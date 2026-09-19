// Package proc — мелочи запуска дочерних программ (ffmpeg и т.п.) из оконного
// приложения SoundFlow.exe.
package proc

import (
	"os"
	"path/filepath"
	"sync"
)

var (
	ffOnce sync.Once
	ffPath string
)

// FFmpeg — что запускать как ffmpeg. Порядок: переменная SOUNDFLOW_FFMPEG,
// ffmpeg.exe рядом с программой (так и задумано в cmd/soundflow/main.go:
// «рядом с exe должны лежать … ffmpeg.exe (или ffmpeg в PATH)»; раньше код
// искал только в PATH и папку программы не смотрел), иначе просто "ffmpeg" из
// PATH.
func FFmpeg() string {
	ffOnce.Do(func() {
		exe, _ := os.Executable()
		ffPath = resolveFFmpeg(os.Getenv("SOUNDFLOW_FFMPEG"), filepath.Dir(exe))
	})
	return ffPath
}

// resolveFFmpeg — сам выбор, отдельно от os.Getenv/os.Executable, чтобы
// проверять тестом.
func resolveFFmpeg(envPath, exeDir string) string {
	if envPath != "" {
		return envPath
	}
	if exeDir != "" && exeDir != "." {
		for _, name := range []string{"ffmpeg.exe", "ffmpeg"} {
			cand := filepath.Join(exeDir, name)
			if fi, err := os.Stat(cand); err == nil && !fi.IsDir() {
				return cand
			}
		}
	}
	return "ffmpeg"
}
