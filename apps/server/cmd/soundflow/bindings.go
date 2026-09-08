package main

import (
	"os/exec"
	"path/filepath"

	wr "github.com/wailsapp/wails/v2/pkg/runtime"
)

// PickFolder — нативный диалог выбора папки. Зовётся из фронта как
// window.go.main.Service.PickFolder().
func (s *Service) PickFolder() (string, error) {
	if s.ctx == nil {
		return "", nil
	}
	return wr.OpenDirectoryDialog(s.ctx, wr.OpenDialogOptions{
		Title: "Папка с музыкой",
	})
}

// RevealPath — открыть папку в Проводнике (кнопка «Открыть папку» в
// «Настройках»). Пусто — открываем папку с базой.
func (s *Service) RevealPath(p string) {
	if p == "" {
		p = s.dbPath
	}
	if p == "" {
		return
	}
	// explorer /select,<файл> — открыть папку и подсветить файл.
	_ = exec.Command("explorer", "/select,", filepath.Clean(p)).Start()
}
