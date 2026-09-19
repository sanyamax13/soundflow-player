//go:build !windows

package proc

import "os/exec"

// Quiet — не Windows: чёрных окон нет, ничего не делаем.
func Quiet(c *exec.Cmd) *exec.Cmd { return c }
