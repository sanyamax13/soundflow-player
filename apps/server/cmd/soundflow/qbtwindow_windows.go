//go:build windows

package main

import (
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// Свернуть окно программы, которую мы сами только что запустили. У qBittorrent нет ключа «запуск
// свёрнутым», а флаг `start /min` она игнорирует (проверено 20.09.2026: окно всё равно выходит на
// экран) — поэтому находим её окна по пути exe и сворачиваем сами, без кражи фокуса.

const (
	swShowMinNoActive         = 7      // SW_SHOWMINNOACTIVE
	processQueryLimitedInform = 0x1000 // PROCESS_QUERY_LIMITED_INFORMATION
)

var (
	wmUser32                     = syscall.NewLazyDLL("user32.dll")
	wmKernel32                   = syscall.NewLazyDLL("kernel32.dll")
	wmEnumWindows                = wmUser32.NewProc("EnumWindows")
	wmIsWindowVisible            = wmUser32.NewProc("IsWindowVisible")
	wmIsIconic                   = wmUser32.NewProc("IsIconic")
	wmGetWindowThreadProcessID   = wmUser32.NewProc("GetWindowThreadProcessId")
	wmShowWindow                 = wmUser32.NewProc("ShowWindow")
	wmOpenProcess                = wmKernel32.NewProc("OpenProcess")
	wmCloseHandle                = wmKernel32.NewProc("CloseHandle")
	wmQueryFullProcessImageNameW = wmKernel32.NewProc("QueryFullProcessImageNameW")
)

// processImagePath — полный путь exe процесса по его номеру ("" — не удалось узнать, например чужой
// процесс с повышенными правами).
func processImagePath(pid uint32) string {
	h, _, _ := wmOpenProcess.Call(processQueryLimitedInform, 0, uintptr(pid))
	if h == 0 {
		return ""
	}
	defer wmCloseHandle.Call(h)
	buf := make([]uint16, 1024)
	size := uint32(len(buf))
	if r, _, _ := wmQueryFullProcessImageNameW.Call(h, 0, uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size))); r == 0 {
		return ""
	}
	return syscall.UTF16ToString(buf[:size])
}

// minimizeWindowsOfExe — свернуть все видимые окна процессов с этим exe; вернуть, сколько свернули.
func minimizeWindowsOfExe(exe string) int {
	want := strings.ToLower(filepath.Clean(exe))
	n := 0
	cb := syscall.NewCallback(func(hwnd, _ uintptr) uintptr {
		if vis, _, _ := wmIsWindowVisible.Call(hwnd); vis == 0 {
			return 1
		}
		if ic, _, _ := wmIsIconic.Call(hwnd); ic != 0 {
			return 1 // уже свёрнуто
		}
		var pid uint32
		wmGetWindowThreadProcessID.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
		if pid == 0 {
			return 1
		}
		if p := processImagePath(pid); p != "" && strings.ToLower(filepath.Clean(p)) == want {
			wmShowWindow.Call(hwnd, swShowMinNoActive)
			n++
		}
		return 1
	})
	wmEnumWindows.Call(cb, 0)
	return n
}

// minimizeWhenShown — ждать до wait, пока у только что запущенной программы появится окно, и свернуть
// его. Окно выходит не сразу (то же время, что и Web UI), поэтому опрашиваем каждые 100 мс.
func minimizeWhenShown(exe string, wait time.Duration) {
	deadline := time.Now().Add(wait)
	for time.Now().Before(deadline) {
		if minimizeWindowsOfExe(exe) > 0 {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}
