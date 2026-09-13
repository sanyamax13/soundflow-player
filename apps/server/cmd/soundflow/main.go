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
		BackgroundColour: &options.RGBA{R: 255, G: 255, B: 255, A: 1},
		OnStartup:        svc.OnStartup,
		OnShutdown:       svc.OnShutdown,
		Windows: &windows.Options{
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
		},
		Bind: []interface{}{svc},
	})
	if err != nil {
		log.Fatal(err)
	}
}
