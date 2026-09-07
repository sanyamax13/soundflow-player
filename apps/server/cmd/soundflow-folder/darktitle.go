package main

import (
	"unsafe"

	"github.com/lxn/win"
	"golang.org/x/sys/windows"
)

// darkTitleBar красит рамку окна в тёмный (Win10 20H1+/Win11), чтобы совпадала
// с тёмным телом окна. На старых сборках просто ничего не делает.
func darkTitleBar(hwnd uintptr) {
	proc := windows.NewLazySystemDLL("dwmapi.dll").NewProc("DwmSetWindowAttribute")
	set := func(attr uintptr, v int32) {
		proc.Call(hwnd, attr, uintptr(unsafe.Pointer(&v)), unsafe.Sizeof(v))
	}
	set(20, 1) // DWMWA_USE_IMMERSIVE_DARK_MODE (Win10 20H1+/Win11)
	set(19, 1) // то же на ранних сборках Win10
	// Явные цвета шапки/рамки под тело окна (Win11): COLORREF = 0x00BBGGRR.
	const cap = 0x00161210 // #0F1216
	const brd = 0x004E4239 // #39424E
	set(35, cap)           // DWMWA_CAPTION_COLOR
	set(34, brd)           // DWMWA_BORDER_COLOR
	// Перерисовать рамку сразу, а не после первого сворачивания.
	win.SetWindowPos(win.HWND(hwnd), 0, 0, 0, 0, 0,
		win.SWP_NOMOVE|win.SWP_NOSIZE|win.SWP_NOZORDER|win.SWP_FRAMECHANGED)
}
