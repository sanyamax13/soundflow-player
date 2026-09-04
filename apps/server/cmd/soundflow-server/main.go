package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"soundflow/server/internal/api"
	"soundflow/server/internal/config"
	"soundflow/server/internal/db"
	"soundflow/server/internal/music"
)

func main() {
	cfg := config.Load()

	ctx := context.Background()
	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		// Не падаем: каркас должен подниматься и без базы. health покажет "down".
		log.Printf("база недоступна на старте (%v) — продолжаю, health скажет down", err)
	}
	if pool != nil {
		if err := pool.Migrate(ctx); err != nil {
			// Тоже не фатально: без базы сервер живёт, синк вернёт 503.
			log.Printf("миграции не применились (%v) — продолжаю", err)
		}
	}

	srv := &api.Server{
		DB:    pool,
		Music: music.New(cfg.MusicDir),
	}

	httpSrv := &http.Server{
		Handler:           srv.Router(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	// tcp4 намеренно: на Windows пустой/0.0.0.0 хост Go биндит только на IPv6
	// (::), и эмулятор Android через 10.0.2.2 (IPv4 loopback хоста) не достаёт.
	ln, err := net.Listen("tcp4", cfg.Addr)
	if err != nil {
		log.Fatalf("не занять адрес %s: %v", cfg.Addr, err)
	}
	go func() {
		log.Printf("SoundFlow server слушает %s (tcp4)", ln.Addr())
		if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
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
