package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"soundflow/server/internal/api"
	"soundflow/server/internal/auth"
	"soundflow/server/internal/config"
	"soundflow/server/internal/db"
)

func main() {
	cfg := config.Load()

	ctx := context.Background()
	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		// Не падаем: каркас должен подниматься и без базы. health покажет "down".
		log.Printf("база недоступна на старте (%v) — продолжаю, health скажет down", err)
	}

	srv := &api.Server{
		Auth: auth.New(cfg.AdminLogin, cfg.AdminPass, cfg.JWTSecret),
		DB:   pool,
	}

	httpSrv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Router(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("SoundFlow server слушает %s", cfg.Addr)
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("сервер упал: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(shutCtx)
	if pool != nil {
		pool.Close()
	}
	log.Println("остановлен")
}
