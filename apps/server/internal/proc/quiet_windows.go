package proc

import (
	"os/exec"
	"syscall"
)

// createNoWindow — CREATE_NO_WINDOW.
const createNoWindow = 0x08000000

// Quiet не даёт консольной программе (ffmpeg, adb…) открыть чёрное окно: мы —
// оконное приложение без консоли, и каждый дочерний ffmpeg иначе моргает своим
// окном (Alex 19.09.2026: «моргает чёрный экран»). Возвращает тот же cmd.
func Quiet(c *exec.Cmd) *exec.Cmd {
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	return c
}
