package main

import (
	"embed"
	"unsafe"

	"golang.org/x/sys/windows"
)

//go:embed fonts/Inter-Regular.ttf fonts/Inter-SemiBold.ttf fonts/Inter-Bold.ttf
var fontFS embed.FS

// loadFonts подгружает Inter в процесс (без установки в систему), чтобы окно
// было тем же шрифтом, что и приложение SoundFlow. Вызывать до создания окна.
func loadFonts() {
	add := windows.NewLazySystemDLL("gdi32.dll").NewProc("AddFontMemResourceEx")
	for _, name := range []string{
		"fonts/Inter-Regular.ttf",
		"fonts/Inter-SemiBold.ttf",
		"fonts/Inter-Bold.ttf",
	} {
		b, err := fontFS.ReadFile(name)
		if err != nil || len(b) == 0 {
			continue
		}
		var count uint32
		add.Call(
			uintptr(unsafe.Pointer(&b[0])),
			uintptr(len(b)),
			0,
			uintptr(unsafe.Pointer(&count)),
		)
	}
}
