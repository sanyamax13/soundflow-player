//go:build headless

// Headless-сборка SoundFlow — сервер без окна. Возвращена 26.09.2026 (Alex TG:
// «сервер плеера крутится на Linux-сервере, а плеер — на ПК brain»). Та же
// начинка, что и в оконной версии; фоном под systemd на Linux-сервере.
// Дашборд — обычным браузером по адресу телефонного API (ту же статику
// отдаёт телефонный сервер).
//
// Сборка:  go build -tags headless -o soundflow-srv ./cmd/soundflow
//
// Переменные окружения:
//
//	SOUNDFLOW_DB          — путь к soundflow.db (иначе ~/.soundflow/)
//	SOUNDFLOW_ASSETS      — папка с onnxruntime и cnn14.onnx (иначе рядом с программой)
//	SOUNDFLOW_ADDR        — адрес телефонного API (иначе :8090)
package main

import (
	"context"
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
	fmt.Println("SoundFlow (headless): запущен, окна нет.")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	fmt.Println("SoundFlow (headless): останавливаюсь…")
	svc.OnShutdown(context.Background())
}
