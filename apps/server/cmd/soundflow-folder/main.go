// soundflow-folder — маленькая программа для тестировщика: указывает папку со
// своей музыкой, программа раздаёт её телефону по Wi-Fi тем же API, что и
// настоящий SoundFlow. Один exe, ничего ставить не нужно (Alex TG 18721–18723).
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
	srv       = NewServer()
	httpOnce  sync.Once
	livePort  string
	mw        *walk.MainWindow
	folderEd  *walk.LineEdit
	countLbl  *walk.Label
	addrEd    *walk.LineEdit
	statusLbl *walk.Label
	startBtn  *walk.PushButton
)

func main() {
	// Папка передана аргументом (перетащили на exe) — подставить и запустить,
	// как только окно создастся.
	go func() {
		arg := autostartArg()
		if arg == "" {
			return
		}
		for mw == nil {
			time.Sleep(20 * time.Millisecond)
		}
		mw.Synchronize(func() {
			folderEd.SetText(arg)
			onStart()
		})
	}()

	if _, err := (MainWindow{
		AssignTo: &mw,
		Title:    "SoundFlow — раздача музыки тестировщику",
		MinSize:  Size{Width: 640, Height: 300},
		Size:     Size{Width: 640, Height: 320},
		Layout: Grid{
			Columns: 1,
			Spacing: 8,
			Margins: Margins{Left: 16, Top: 16, Right: 16, Bottom: 16},
		},
		Children: []Widget{
			Label{Text: "1. Папка со своей музыкой (можно на любом диске):"},
			LineEdit{AssignTo: &folderEd, ReadOnly: true, Text: loadLastFolder()},
			PushButton{Text: "Выбрать папку…", OnClicked: onPick},

			PushButton{
				AssignTo:  &startBtn,
				Text:      "2. Запустить раздачу",
				MinSize:   Size{Height: 34},
				OnClicked: onStart,
			},

			Label{AssignTo: &countLbl, Text: ""},

			Label{Text: "3. Впиши этот адрес в SoundFlow на телефоне, потом «докачать всё»:"},
			LineEdit{
				AssignTo: &addrEd, ReadOnly: true, Text: "",
				Font: Font{PointSize: 12, Bold: true},
			},

			Label{AssignTo: &statusLbl, Text: "Выбери папку и нажми «Запустить раздачу»."},

			VSpacer{},
			Label{
				Text:      "Телефон и этот компьютер должны быть в одной Wi-Fi сети. Окно не закрывать.",
				TextColor: walk.RGB(110, 110, 110),
			},
		},
	}).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// init: путь папки можно передать аргументом (перетащить папку на exe) —
// тогда сразу подставляем и запускаем раздачу.
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
	dlg.InitialDirPath = folderEd.Text()
	if ok, err := dlg.ShowBrowseFolder(mw); err == nil && ok {
		folderEd.SetText(dlg.FilePath)
		saveLastFolder(dlg.FilePath)
	}
}

func onStart() {
	dir := strings.TrimSpace(folderEd.Text())
	if dir == "" {
		walk.MsgBox(mw, "Нет папки", "Сначала выбери папку с музыкой.", walk.MsgBoxIconWarning)
		return
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		walk.MsgBox(mw, "Папка не найдена", "Такой папки нет: "+dir, walk.MsgBoxIconError)
		return
	}
	startBtn.SetEnabled(false)
	statusLbl.SetText("Читаю песни…")
	countLbl.SetText("")
	addrEd.SetText("")

	go func() {
		items, err := Scan(dir, func(n int) {
			if n%25 == 0 {
				mw.Synchronize(func() { statusLbl.SetText(fmt.Sprintf("Читаю песни… %d", n)) })
			}
		})
		mw.Synchronize(func() {
			startBtn.SetEnabled(true)
			if err != nil {
				statusLbl.SetText("Ошибка чтения папки: " + err.Error())
				return
			}
			if len(items) == 0 {
				statusLbl.SetText("В этой папке не нашёл музыкальных файлов (mp3, m4a, flac…).")
				return
			}
			srv.SetItems(items)
			countLbl.SetText(fmt.Sprintf("Песен готово к раздаче: %d", len(items)))

			if err := ensureHTTP(); err != nil {
				statusLbl.SetText("Не удалось открыть сеть: " + err.Error())
				return
			}
			host := LANAddr()
			if host == "" {
				host = "127.0.0.1"
			}
			addrEd.SetText("http://" + host + ":" + livePort)
			statusLbl.SetText("Работает. Раздаю музыку — можно качать на телефон.")
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
			p := 8090 + i + 1
			port = fmt.Sprint(p)
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

// --- запоминаем последнюю папку рядом в %APPDATA%\SoundFlowFolder\last.txt ---

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
