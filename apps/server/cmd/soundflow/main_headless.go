//go:build headless

// Headless-сборка SoundFlow — для сервера (мини-ПК fg), где программа работает
// фоном, без окна, запускается планировщиком/службой. Та же начинка, что и в
// оконной версии: SQLite (soundflow.db) + отпечаток в процессе (onnxruntime.dll
// + cnn14.onnx) + телефонный API на :8090. Дашборд открывается обычным браузером
// по http://<этот-ПК>:8090/ (ту же статику отдаёт телефонный сервер).
//
// Сборка:  go build -tags headless -o soundflow-srv.exe ./cmd/soundflow
// Wails/WebView2 в этой сборке не участвуют.
//
// Переменные окружения (как в старом run.cmd):
//   SOUNDFLOW_DB          — путь к soundflow.db (иначе %LocalAppData%\SoundFlow\)
//   SOUNDFLOW_ASSETS      — папка с onnxruntime.dll и cnn14.onnx (иначе рядом с exe)
//   SOUNDFLOW_ADDR        — адрес телефонного API (иначе :8090)
//   SOUNDFLOW_AUDIO_ROOT  — заменяет префикс E:\soundflow-data (на fg: D:\SoundFlow)
package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	svc, err := NewService()
	if err != nil {
		fmt.Fprintf(os.Stderr, "SoundFlow: %v\n", err)
		os.Exit(1)
	}
	svc.frontend = assets
	fmt.Println("SoundFlow (headless): запущен, окна нет. Дашборд — в браузере по адресу из строки выше.")

	// Ждём Ctrl+C / завершение службы, потом аккуратно гасим — то же, что делает
	// OnShutdown в оконной версии.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	fmt.Println("SoundFlow (headless): останавливаюсь…")
	if svc.phoneSrv != nil {
		_ = svc.phoneSrv.Close()
	}
	svc.jobs.CancelAll()
	if svc.eng != nil {
		_ = svc.eng.Close()
	}
	_ = svc.db.Close()
}
