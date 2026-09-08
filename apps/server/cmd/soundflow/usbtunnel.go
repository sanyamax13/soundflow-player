package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// USB-туннель: держим `adb reverse tcp:<port> tcp:<port>` живым, пока телефон
// в кабеле. Тогда всё, что телефон шлёт на 127.0.0.1:<port>, идёт по проводу
// на этот ПК — Wi-Fi не нужен (Alex 08.09.2026: «только USB»).
//
// adb.exe (+ AdbWinApi.dll, AdbWinUsbApi.dll) кладётся рядом с программой.
// Нет adb — тихо выключено, работает только Wi-Fi по IP.

type usbTunnel struct {
	adb  string
	port string

	mu    sync.RWMutex
	state string // человекочитаемо для окна
	up    bool
}

var usb = &usbTunnel{state: "не запущен"}

func startUSBTunnel(phoneAddr string) {
	port := phoneAddr
	if i := strings.LastIndex(port, ":"); i >= 0 {
		port = port[i+1:]
	}
	if port == "" {
		port = "8090"
	}
	adb := filepath.Join(exeDir(), "adb.exe")
	if _, err := os.Stat(adb); err != nil {
		usb.setDown("нет adb рядом с программой — только Wi-Fi")
		return
	}
	usb.adb, usb.port = adb, port
	go usb.loop()
}

func (t *usbTunnel) loop() {
	for {
		t.tick()
		time.Sleep(5 * time.Second)
	}
}

func (t *usbTunnel) tick() {
	out, err := hiddenCmd(t.adb, "devices")
	if err != nil {
		t.setDown("adb не отвечает")
		return
	}
	var serials []string
	for _, ln := range strings.Split(out, "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasPrefix(ln, "List of devices") {
			continue
		}
		f := strings.Fields(ln)
		if len(f) >= 2 && f[1] == "device" {
			serials = append(serials, f[0])
		}
	}
	if len(serials) == 0 {
		t.setDown("телефон не подключён по USB")
		return
	}
	if rl, _ := hiddenCmd(t.adb, "reverse", "--list"); strings.Contains(rl, "tcp:"+t.port+" tcp:"+t.port) {
		t.setUp()
		return
	}
	if _, err := hiddenCmd(t.adb, "-s", serials[0], "reverse", "tcp:"+t.port, "tcp:"+t.port); err != nil {
		t.setDown("не поднять туннель")
		return
	}
	t.setUp()
}

func (t *usbTunnel) setUp() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.up {
		_ = writeServerLogSafe("телефон подключён по кабелю, туннель поднят")
	}
	t.up, t.state = true, "работает по кабелю"
}

func (t *usbTunnel) setDown(why string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.up, t.state = false, why
}

// Status — для окна: {enabled, up, text}.
func (t *usbTunnel) Status() map[string]any {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return map[string]any{"enabled": t.adb != "", "up": t.up, "text": t.state}
}

// writeServerLogSafe — необязательная запись в лог сервера (usbTunnel не держит
// ссылку на Service). Подменяется в service.go при старте.
var writeServerLogSafe = func(string) error { return nil }
