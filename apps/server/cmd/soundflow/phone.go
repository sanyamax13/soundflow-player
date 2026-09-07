package main

import (
	"encoding/json"
	"net/http"
	"os"
	"time"

	"github.com/dhowden/tag"
	"github.com/go-chi/chi/v5"

	"soundflow/server/internal/localdb"
)

// Телефонный HTTP-API на SQLite. Тот же путь /v1/*, что у старого сервера, но
// без Postgres. В этот заход — чтение + радио + приём событий синка.
func (s *Service) startPhoneServer() {
	r := chi.NewRouter()
	r.Get("/v1/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]any{"ok": true, "db": "sqlite", "tracks": s.countTracks()})
	})
	r.Get("/v1/tracks", func(w http.ResponseWriter, req *http.Request) {
		lim := atoiDef(req.URL.Query().Get("limit"), 20000)
		list, err := s.db.CatalogList(lim)
		httpJSON(w, list, err)
	})
	r.Get("/v1/search", func(w http.ResponseWriter, req *http.Request) {
		list, err := s.db.CatalogSearch(req.URL.Query().Get("q"), atoiDef(req.URL.Query().Get("limit"), 100))
		httpJSON(w, list, err)
	})
	r.Get("/v1/music/{id}/file", s.hAudio)
	r.Get("/v1/cover/{id}", func(w http.ResponseWriter, req *http.Request) {
		id := chi.URLParam(req, "id")
		if url, ok, _ := s.db.TrackCoverURL(id); ok && (len(url) > 4 && url[:4] == "http") {
			http.Redirect(w, req, url, http.StatusFound)
			return
		}
		// обложка из тегов файла
		path, ok, _ := s.db.TrackFilePath(id)
		if !ok {
			http.Error(w, "нет обложки", 404)
			return
		}
		if pic := embeddedCover(s.localPath(path)); pic != nil {
			w.Header().Set("Content-Type", pic.mime)
			_, _ = w.Write(pic.data)
			return
		}
		http.Error(w, "нет обложки", 404)
	})
	r.Post("/v1/stream/order", func(w http.ResponseWriter, req *http.Request) {
		var body struct {
			SeedID       string   `json:"seed_id"`
			CandidateIDs []string `json:"candidate_ids"`
		}
		_ = json.NewDecoder(req.Body).Decode(&body)
		cands := body.CandidateIDs
		if len(cands) == 0 {
			cands, _ = s.db.CandidateIDsAll(0)
		}
		ordered, reordered, err := s.db.OrderBySimilarity(body.SeedID, cands)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, map[string]any{"ordered": ordered, "reordered": reordered})
	})
	r.Post("/v1/library/next-batch", func(w http.ResponseWriter, req *http.Request) {
		var body struct {
			ExcludeIDs  []string `json:"exclude_ids"`
			BudgetBytes int64    `json:"budget_bytes"`
		}
		_ = json.NewDecoder(req.Body).Decode(&body)
		if body.BudgetBytes <= 0 {
			body.BudgetBytes = 1 << 30
		}
		list, total, err := s.db.NextLibraryBatch(body.ExcludeIDs, body.BudgetBytes)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, map[string]any{"tracks": list, "total_bytes": total})
	})
	r.Post("/v1/sync/events", func(w http.ResponseWriter, req *http.Request) {
		var body struct {
			Device struct {
				ID, Name, AppVersion string
				MusicBytes           int64 `json:"music_bytes"`
			} `json:"device"`
			Events []localdb.SyncEvent `json:"events"`
		}
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		acc, err := s.db.SaveSync(localdb.Device{
			ID: body.Device.ID, Name: body.Device.Name,
			AppVersion: body.Device.AppVersion, MusicBytes: body.Device.MusicBytes,
		}, body.Events)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, map[string]any{"accepted": acc, "count": len(acc)})
	})
	r.Get("/v1/sync/report", func(w http.ResponseWriter, req *http.Request) {
		dev := req.URL.Query().Get("device")
		last, total, err := s.db.SyncReport(dev)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, map[string]any{"last_sync": last, "total_events": total})
	})

	// то же окно доступно и в обычном браузере: /api/* + вшитый frontend
	s.mountAPI(r)
	r.Handle("/*", s.staticHandler())

	s.phoneSrv = &http.Server{Addr: s.phoneAddr, Handler: r, ReadHeaderTimeout: 10 * time.Second}
	_ = s.db.AddServerLog("info", "", "", "телефонный API слушает "+s.phoneAddr, 0)
	if err := s.phoneSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		_ = s.db.AddServerLog("error", "", "", "телефонный API упал: "+err.Error(), 0)
	}
}

func (s *Service) countTracks() int64 {
	c, _ := s.db.Counts()
	return c.Tracks
}

func httpJSON(w http.ResponseWriter, v any, err error) {
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, v)
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
