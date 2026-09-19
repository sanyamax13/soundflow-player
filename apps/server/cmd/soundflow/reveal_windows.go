//go:build windows

package main

import (
	"fmt"
	"os/exec"
	"strings"
	"syscall"
)

// explorer.exe сам разбирает командную строку: «/select,"путь"» с кавычками
// внутри одного аргумента. Обычный exec.Command обернул бы весь аргумент в
// кавычки и проводник открыл бы просто «Документы» — поэтому CmdLine целиком.
func runExplorer(cmdline string) error {
	if strings.Contains(cmdline, "\r") || strings.Contains(cmdline, "\n") {
		return fmt.Errorf("недопустимый путь")
	}
	cmd := exec.Command("explorer.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: cmdline}
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() { _ = cmd.Wait() }() // explorer.exe возвращает 1 даже при успехе — код не смотрим
	return nil
}

func revealInExplorer(path string) error {
	if strings.Contains(path, `"`) {
		return fmt.Errorf("недопустимый путь")
	}
	return runExplorer(`explorer.exe /select,"` + path + `"`)
}

func openFolderInExplorer(path string) error {
	if strings.Contains(path, `"`) {
		return fmt.Errorf("недопустимый путь")
	}
	return runExplorer(`explorer.exe "` + path + `"`)
}
