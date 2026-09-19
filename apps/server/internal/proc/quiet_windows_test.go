package proc

import (
	"os/exec"
	"testing"
)

func TestQuietHidesConsoleWindow(t *testing.T) {
	c := Quiet(exec.Command("cmd", "/c", "echo", "x"))
	if c.SysProcAttr == nil || !c.SysProcAttr.HideWindow || c.SysProcAttr.CreationFlags&createNoWindow == 0 {
		t.Fatalf("окно не спрятано: %+v", c.SysProcAttr)
	}
	if out, err := c.Output(); err != nil || len(out) == 0 {
		t.Errorf("процесс со спрятанным окном должен работать: %q %v", out, err)
	}
}
