//go:build windows

// Package diskspace — сколько места свободно на диске под музыку (экран
// «Сервер», пункт 10). Отдельные файлы под ОС: fg и машина разработки —
// Windows, тесты гоняются там же.
package diskspace

import (
	"syscall"
	"unsafe"
)

// Free возвращает свободные и общие байты тома, на котором лежит path.
func Free(path string) (free, total int64, err error) {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0, 0, err
	}
	getDiskFreeSpaceEx := syscall.NewLazyDLL("kernel32.dll").NewProc("GetDiskFreeSpaceExW")
	var freeAvail, totalBytes, totalFree uint64
	r1, _, e1 := getDiskFreeSpaceEx.Call(
		uintptr(unsafe.Pointer(p)),
		uintptr(unsafe.Pointer(&freeAvail)),
		uintptr(unsafe.Pointer(&totalBytes)),
		uintptr(unsafe.Pointer(&totalFree)),
	)
	if r1 == 0 {
		return 0, 0, e1
	}
	return int64(freeAvail), int64(totalBytes), nil
}
