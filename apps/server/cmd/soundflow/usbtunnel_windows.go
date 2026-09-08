//go:build windows

package main

import (
	"context"
	"os/exec"
	"syscall"
	"time"
)

// hiddenCmd запускает adb.exe без всплывающего чёрного окна (программа сама
// -H windowsgui, дочерний консольный процесс иначе моргает). Таймаут 15 c.
// CREATE_NO_WINDOW = 0x08000000.
func hiddenCmd(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	c := exec.CommandContext(ctx, name, args...)
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	out, err := c.Output()
	return string(out), err
}
