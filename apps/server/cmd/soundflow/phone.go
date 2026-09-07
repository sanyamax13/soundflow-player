package main

import (
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/dhowden/tag"
	"github.com/go-chi/chi/v5"

	"soundflow/server/internal/api"
	"soundflow/server/internal/config"
	"soundflow/server/internal/litestore"
	"soundflow/server/internal/music"
	"soundflow/server/internal/pathmap"
)

// startPhoneServer поднимает HTTP на :8090:
//   - /v1/*  — телефонный + админский API. Тот же проверенный код, что у старого
//     сервера (internal/api), только база — SQLite через litestore, а не Postgres.
//   - /api/* — ручки окна-дашборда (тот же дашборд открывается и браузером).
//   - /*     — вшитый frontend.
//
// Acquire («Добавить музыку») пока не подключён — до перевода Python-качалки в
// тонкий сервис; соответствующие ручки честно отвечают 503 (s.Acquire == nil).
func (s *Service) startPhoneServer() {
	cfg := config.Load()

	pm := cfg.PathMap
	if len(pm.LocalRoots()) == 0 {
		if root := os.Getenv("SOUNDFLOW_AUDIO_ROOT"); root != "" {
			pm = pathmap.New(
				pathmap.Pair{Canonical: `E:\soundflow-data\cache`, Local: filepath.Join(root, "cache")},
				pathmap.Pair{Canonical: `E:\soundflow-data\music`, Local: filepath.Join(root, "music")},
			)
		}
	}

	apiSrv := &api.Server{
		DB:                 litestore.New(s.db),
		Music:              music.New(cfg.MusicDir),
		PathMap:            pm,
		StartedAt:          s.startedAt,
		GeneratedCoversDir: cfg.GeneratedCoversDir,
	}

	r := chi.NewRouter()
	// /v1/* целиком отдаём проверенному роутеру internal/api (он сам маршрутит
	// от /v1). chi.Handle не срезает префикс — путь приходит как есть.
	r.Handle("/v1/*", apiSrv.Router())

	// то же окно доступно и в обычном браузере: /api/* + вшитый frontend
	s.mountAPI(r)
	r.Handle("/*", s.staticHandler())

	s.phoneSrv = &http.Server{Addr: s.phoneAddr, Handler: r, ReadHeaderTimeout: 10 * time.Second}
	_ = s.db.AddServerLog("info", "", "", "телефонный API слушает "+s.phoneAddr, 0)
	if err := s.phoneSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		_ = s.db.AddServerLog("error", "", "", "телефонный API упал: "+err.Error(), 0)
	}
}

type cover struct {
	mime string
	data []byte
}

func embeddedCover(path string) *cover {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	m, err := tag.ReadFrom(f)
	if err != nil || m == nil || m.Picture() == nil {
		return nil
	}
	p := m.Picture()
	mime := p.MIMEType
	if mime == "" {
		mime = "image/jpeg"
	}
	return &cover{mime: mime, data: p.Data}
}
