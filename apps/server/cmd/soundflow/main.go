//go:build !headless

// SoundFlow.exe — «сервер в одном приложении»: окно (WebView2 через Wails),
// каталог в SQLite (soundflow.db), звуковой отпечаток в этом же процессе
// (onnxruntime.dll + cnn14.onnx), без Docker и Python.
//
// Рядом с exe должны лежать: onnxruntime.dll, cnn14.onnx (+ cnn14.onnx.data),
// ffmpeg.exe (или ffmpeg в PATH). База и логи — в %LocalAppData%\SoundFlow\.
//
// Безоконная (headless) сборка убрана 14.09.2026 — единственный, кто её
// использовал (fg), уходит в пользу этой же оконной программы на компе
// Alex; см. docs/PROGRESS.md этапы 72/76.
package main

import (
	"log"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

func main() {
	if remote := remoteServerURL(); remote != "" {
		runRemoteWindow(remote)
		return
	}
	svc, err := NewService()
	if err != nil {
		log.Fatalf("SoundFlow: %v", err)
	}
	svc.frontend = assets

	err = wails.Run(&options.App{
		Title:     "SoundFlow",
		Width:     1280,
		Height:    820,
		MinWidth:  980,
		MinHeight: 640,
		AssetServer: &assetserver.Options{
			Assets:  assets,
			Handler: svc.APIRouter(), // всё, что не статика (/api/*, /audio/*)
		},
		BackgroundColour: &options.RGBA{R: 0, G: 0, B: 0, A: 0},
		OnStartup:        svc.OnStartup,
		OnShutdown:       svc.OnShutdown,
		Windows: &windows.Options{
			WebviewIsTransparent: true,
			WindowIsTranslucent:  true,
			BackdropType:         windows.Mica,
			Theme:                windows.Dark,
		},
		Bind: []interface{}{svc},
	})
	if err != nil {
		log.Fatal(err)
	}
}

// runRemoteWindow — окно в режиме «только плеер»: свой сервер не запускаем, всё идёт на remote (см. remote.go).
func runRemoteWindow(remote string) {
	proxy, err := remoteProxy(remote)
	if err != nil {
		log.Fatalf("SoundFlow: адрес сервера %q: %v", remote, err)
	}
	err = wails.Run(&options.App{
		Title:     "SoundFlow",
		Width:     1280,
		Height:    820,
		MinWidth:  980,
		MinHeight: 640,
		AssetServer: &assetserver.Options{
			Assets:  assets,
			Handler: proxy,
		},
		// Тёмное стекло Windows 11 (Mica) под окном — как на телефоне (разбор Gemini 26.09.2026, Alex).
		// Параметры по документации Wails v2 (context7): прозрачный WebView + полупрозрачное окно + BackdropType.
		BackgroundColour: &options.RGBA{R: 0, G: 0, B: 0, A: 0},
		Windows: &windows.Options{
			WebviewIsTransparent: true,
			WindowIsTranslucent:  true,
			BackdropType:         windows.Mica,
			Theme:                windows.Dark,
		},
	})
	if err != nil {
		log.Fatal(err)
	}
}
