//go:build !windows

package main

import (
	"context"
	"os/exec"
	"time"
)

func hiddenCmd(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	return string(out), err
}
