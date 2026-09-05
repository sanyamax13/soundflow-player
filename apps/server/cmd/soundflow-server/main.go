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

	"soundflow/server/internal/acquire"
	"soundflow/server/internal/api"
	"soundflow/server/internal/config"
	"soundflow/server/internal/db"
	"soundflow/server/internal/legacy"
	"soundflow/server/internal/music"
	"soundflow/server/internal/sidecar"
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
		// Миграции и перенос разметки — в фоне с повторами, пока не выйдет.
		// После ребута fg docker поднимается не сразу; раньше сервер стартовал
		// с базой down и так и висел без схемы до ручного перезапуска
		// (06.09.2026). Теперь докатывает сам, как только база отвечает.
		go ensureSchema(ctx, pool)
	}

	sc := sidecar.New(cfg.SidecarURL)
	if err := sc.Health(ctx); err != nil {
		log.Printf("сайдкар %s недоступен (%v) — скачивание не заработает, остальное живёт", cfg.SidecarURL, err)
	} else {
		log.Printf("сайдкар на связи: %s", cfg.SidecarURL)
	}

	srv := &api.Server{
		DB:                 pool,
		Music:              music.New(cfg.MusicDir),
		Acquire:            &acquire.Service{DB: pool, Finder: sc},
		PathMap:            cfg.PathMap,
		StartedAt:          time.Now(),
		GeneratedCoversDir: cfg.GeneratedCoversDir,
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

// ensureSchema накатывает миграции и перенос старой разметки, повторяя
// попытки, пока база не станет доступна (после ребута fg docker поднимается
// с задержкой). Бэкофф 5с → 1 мин. Перенос разметки не критичен — из-за
// него не зацикливаемся.
func ensureSchema(ctx context.Context, pool *db.Pool) {
	for attempt := 1; ; attempt++ {
		wait := time.Duration(attempt) * 5 * time.Second
		if wait > time.Minute {
			wait = time.Minute
		}
		if err := pool.Ping(ctx); err != nil {
			log.Printf("схема: база пока недоступна (попытка %d, ещё через %s): %v", attempt, wait, err)
			time.Sleep(wait)
			continue
		}
		if err := pool.Migrate(ctx); err != nil {
			log.Printf("схема: миграции не применились (попытка %d, ещё через %s): %v", attempt, wait, err)
			time.Sleep(wait)
			continue
		}
		if n, err := legacy.Seed(ctx, pool); err != nil {
			log.Printf("схема: перенос разметки старого плеера не удался (%v) — не критично", err)
		} else if n > 0 {
			log.Printf("схема: перенесена разметка старого плеера: %d записей", n)
		}
		log.Printf("схема готова (попытка %d)", attempt)
		return
	}
}
