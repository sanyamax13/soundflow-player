package main

import (
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
