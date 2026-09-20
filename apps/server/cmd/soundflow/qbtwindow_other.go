//go:build !windows

package main

import "time"

// Свёртывание окна нужно только на Windows.
func minimizeWhenShown(exe string, wait time.Duration) {}
