package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"soundflow/server/internal/acquire"
	"soundflow/server/internal/db"
	"soundflow/server/internal/music"
	"soundflow/server/internal/pathmap"
)

type Server struct {
	DB        *db.Pool
	Music     *music.Service
	Acquire   *acquire.Service
	PathMap   pathmap.Mapper
	StartedAt time.Time
}

func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	// Входа нет — плеер личный, сервер в домашней сети. Все ручки открыты.
	r.Route("/v1", func(r chi.Router) {
		// Быстрые ручки — жёсткий таймаут.
		r.Group(func(r chi.Router) {
			r.Use(middleware.Timeout(15 * time.Second))
			r.Get("/health", s.health)
			r.Get("/tracks", s.tracks)
			r.Get("/search", s.search)
			r.Post("/library/next-batch", s.libraryNextBatch)
			r.Post("/stream/order", s.streamOrder)
			r.Post("/sync/events", s.syncEvents)
			r.Get("/sync/report", s.syncReport)
			r.Route("/admin", func(r chi.Router) {
				r.Get("/status", s.adminStatus)
				r.Get("/devices", s.adminDevices)
				r.Get("/events", s.adminEvents)
				r.Post("/reanalyze", s.adminReanalyze)
				r.Post("/sweep-junk", s.adminSweepJunk)
				r.Post("/import-library", s.adminImportLibrary)
			})
		})
		// Скачивание трека через цепочку источников — минуты.
		r.Group(func(r chi.Router) {
			r.Use(middleware.Timeout(10 * time.Minute))
			r.Post("/tracks/acquire", s.acquireTrack)
		})
		// Отдача файла — потоковая, без таймаута.
		r.Get("/music/{id}/file", s.musicFile)
	})
	return r
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	dbState := "ok"
	if err := s.DB.Ping(r.Context()); err != nil {
		dbState = "down"
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"status": "alive",
		"db":     dbState,
	})
}

func (s *Server) tracks(w http.ResponseWriter, r *http.Request) {
	// Есть каталог — отдаём его; пусто — тестовые тоны (для демо до наполнения).
	if s.DB.Ping(r.Context()) == nil {
		if list, err := s.DB.CatalogList(r.Context(), 500); err == nil && len(list) > 0 {
			writeJSON(w, http.StatusOK, map[string]any{"tracks": list})
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"tracks": s.Music.List()})
}

func (s *Server) musicFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	// Настоящий трек из каталога — отдаём файл с диска (канонический путь → реальный).
	if s.DB.Ping(r.Context()) == nil {
		if canonical, ok, err := s.DB.TrackFilePath(r.Context(), id); err == nil && ok {
			http.ServeFile(w, r, s.PathMap.ToLocal(canonical))
			return
		}
	}
	// Иначе — тестовый тон / файл из локальной папки.
	s.Music.ServeFile(w, r, id)
}

// --- Синхронизация телефон → сервер (этап 3) ---

type syncReq struct {
	Device struct {
		ID         string `json:"id"`
		Name       string `json:"name"`
		AppVersion string `json:"app_version"`
		MusicBytes int64  `json:"music_bytes"`
	} `json:"device"`
	Events []db.SyncEvent `json:"events"`
}

func (s *Server) syncEvents(w http.ResponseWriter, r *http.Request) {
	var req syncReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "битый json"})
		return
	}
	if req.Device.ID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен device.id"})
		return
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	accepted, err := s.DB.SaveSync(r.Context(), db.Device{
		ID:         req.Device.ID,
		Name:       req.Device.Name,
		AppVersion: req.Device.AppVersion,
		MusicBytes: req.Device.MusicBytes,
	}, req.Events)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if accepted == nil {
		accepted = []string{}
	}
	s.handleDeleteEvents(r.Context(), req.Events, accepted)
	writeJSON(w, http.StatusOK, map[string]any{
		"accepted":    accepted,
		"server_time": time.Now().UTC().Format(time.RFC3339),
	})
}

// handleDeleteEvents — Alex удалил трек на телефоне ("Моя музыка" → корзина).
// Сервер должен увидеть это и тоже убрать трек у себя: помечает его blocked в
// legacy_marks (не попадёт в каталог/повторный импорт/повторное скачивание)
// и переносит файл в _trash рядом с его корнем — не удаляет насовсем, мало ли
// трек не тот или Alex передумает. Обрабатываем только реально новые события
// (accepted), чтобы не дёргать файл при каждом повторном синке.
func (s *Server) handleDeleteEvents(ctx context.Context, events []db.SyncEvent, accepted []string) {
	acc := make(map[string]bool, len(accepted))
	for _, id := range accepted {
		acc[id] = true
	}
	for _, e := range events {
		if e.Kind != "delete" || e.TrackID == "" || !acc[e.UUID] {
			continue
		}
		normKey, canonical, ok, err := s.DB.TrackForDeletion(ctx, e.TrackID)
		if err != nil {
			log.Printf("delete-event %s: поиск трека: %v", e.TrackID, err)
			continue
		}
		if !ok {
			continue // трек не наш (тестовый тон и т.п.) — нечего чистить
		}
		if err := s.DB.UpsertLegacyMark(ctx, db.LegacyMark{Key: normKey, Kind: "blocked"}); err != nil {
			log.Printf("delete-event %s: пометить blocked: %v", e.TrackID, err)
		}
		local := s.PathMap.ToLocal(canonical)
		if err := pathmap.MoveToTrash(s.PathMap, local); err != nil {
			log.Printf("delete-event %s: файл в корзину (%s): %v", e.TrackID, local, err)
		} else {
			log.Printf("delete-event %s: убран у себя (%s)", e.TrackID, local)
		}
	}
}

func (s *Server) syncReport(w http.ResponseWriter, r *http.Request) {
	dev := r.URL.Query().Get("device")
	if dev == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен параметр device"})
		return
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	last, total, err := s.DB.SyncReport(r.Context(), dev)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	out := map[string]any{"total_events": total}
	if last != nil {
		out["last_sync_at"] = last.UTC().Format(time.RFC3339)
	}
	writeJSON(w, http.StatusOK, out)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
