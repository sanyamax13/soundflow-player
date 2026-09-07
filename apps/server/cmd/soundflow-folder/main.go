// soundflow-folder — маленькая программа для тестировщика: указывает папку со
// своей музыкой, программа раздаёт её телефону по Wi-Fi тем же API, что и
// настоящий SoundFlow. Один exe, ничего ставить не нужно (Alex TG 18721–18729).
// Вид — тёмный, в духе ФармМастера (весь экран рисуется в ui.go).
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/lxn/walk"
	//lint:ignore ST1001 walk declarative API так и задуман
	. "github.com/lxn/walk/declarative"
)

const preferredPort = "8090"

var (
	srv      = NewServer()
	httpOnce sync.Once
	livePort string
	mw       *walk.MainWindow
	U        = newUI()
)

func main() {
	loadFonts() // Inter в процесс — до создания окна
	U.folder = loadLastFolder()

	// Автозапуск, если папку передали аргументом (перетащили на exe).
	go func() {
		for mw == nil || U.cw == nil {
			time.Sleep(20 * time.Millisecond)
		}
		arg := autostartArg()
		if arg == "" {
			return
		}
		mw.Synchronize(func() {
			U.setFolder(arg)
			onStart()
		})
	}()

	if _, err := (MainWindow{
		AssignTo:   &mw,
		Title:      "SoundFlow",
		MinSize:    Size{Width: 560, Height: 490},
		Size:       Size{Width: 560, Height: 490},
		Layout:     VBox{MarginsZero: true, SpacingZero: true},
		Background: SolidColorBrush{Color: cBg},
		Children: []Widget{
			CustomWidget{
				AssignTo:            &U.cw,
				ClearsBackground:    true,
				InvalidatesOnResize: true,
				Paint:               U.paint,
				OnMouseDown:         U.onMouseDown,
				OnMouseMove:         U.onMouseMove,
			},
		},
	}).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// autostartArg — путь папки можно передать аргументом (перетащить папку на exe).
func autostartArg() string {
	if len(os.Args) > 1 {
		if fi, err := os.Stat(os.Args[1]); err == nil && fi.IsDir() {
			return os.Args[1]
		}
	}
	return ""
}

func onPick() {
	dlg := new(walk.FileDialog)
	dlg.Title = "Папка с музыкой"
	dlg.InitialDirPath = U.folder
	if ok, err := dlg.ShowBrowseFolder(mw); err == nil && ok {
		U.setFolder(dlg.FilePath)
		saveLastFolder(dlg.FilePath)
	}
}

func onStart() {
	dir := strings.TrimSpace(U.folder)
	if dir == "" {
		walk.MsgBox(mw, "Нет папки", "Сначала выбери папку с музыкой.", walk.MsgBoxIconWarning)
		return
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		walk.MsgBox(mw, "Папка не найдена", "Такой папки нет:\n"+dir, walk.MsgBoxIconError)
		return
	}
	U.setBusy()

	go func() {
		items, err := Scan(dir, func(n int) {
			if n%25 == 0 {
				mw.Synchronize(func() { U.setScanProgress(n) })
			}
		})
		mw.Synchronize(func() {
			if err != nil {
				U.setError("Не прочитать папку: " + err.Error())
				return
			}
			if len(items) == 0 {
				U.setError("В этой папке нет музыкальных файлов (mp3, m4a, flac…).")
				return
			}
			srv.SetItems(items)
			if err := ensureHTTP(); err != nil {
				U.setError("Не открыть сеть: " + err.Error())
				return
			}
			host := LANAddr()
			if host == "" {
				host = "127.0.0.1"
			}
			U.setRunning(len(items), "http://"+host+":"+livePort)
		})
	}()
}

// ensureHTTP поднимает сервер один раз, на первом свободном порту начиная
// с preferredPort.
func ensureHTTP() error {
	var startErr error
	httpOnce.Do(func() {
		var ln net.Listener
		port := preferredPort
		for i := 0; i < 20; i++ {
			l, err := net.Listen("tcp", "0.0.0.0:"+port)
			if err == nil {
				ln = l
				break
			}
			port = fmt.Sprint(8090 + i + 1)
		}
		if ln == nil {
			startErr = fmt.Errorf("порты 8090–8110 заняты")
			return
		}
		livePort = port
		s := &http.Server{Handler: srv.Handler(), ReadHeaderTimeout: 10 * time.Second}
		go func() { _ = s.Serve(ln) }()
	})
	return startErr
}

// --- запоминаем последнюю папку в %APPDATA%\SoundFlowFolder\last.txt ---

func cfgPath() string {
	base, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	dir := filepath.Join(base, "SoundFlowFolder")
	_ = os.MkdirAll(dir, 0o755)
	return filepath.Join(dir, "last.txt")
}

func loadLastFolder() string {
	p := cfgPath()
	if p == "" {
		return ""
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func saveLastFolder(path string) {
	if p := cfgPath(); p != "" {
		_ = os.WriteFile(p, []byte(path), 0o644)
	}
}
