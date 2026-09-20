//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Путь exe по номеру процесса — основа поиска окон «своей» программы: для самого теста это его же exe.
func TestProcessImagePathOfSelf(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Skip(err)
	}
	got := processImagePath(uint32(os.Getpid()))
	if got == "" || !strings.EqualFold(filepath.Clean(got), filepath.Clean(self)) {
		t.Fatalf("processImagePath(self)=%q, ждал %q", got, self)
	}
}

// Чужой exe без окон — ничего не сворачиваем и не падаем.
func TestMinimizeWindowsOfUnknownExeIsNoop(t *testing.T) {
	if n := minimizeWindowsOfExe(`Z:\нет\такой\программы.exe`); n != 0 {
		t.Fatalf("свернули %d окон чужой программы", n)
	}
}
