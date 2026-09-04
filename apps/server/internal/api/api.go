package api

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"soundflow/server/internal/db"
	"soundflow/server/internal/music"
)

type Server struct {
	DB    *db.Pool
	Music *music.Service
}

func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(15 * time.Second))

	// Входа нет — плеер личный, сервер в домашней сети. Все ручки открыты.
	r.Route("/v1", func(r chi.Router) {
		r.Get("/health", s.health)
		r.Get("/tracks", s.tracks)
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
	writeJSON(w, http.StatusOK, map[string]any{"tracks": s.Music.List()})
}

func (s *Server) musicFile(w http.ResponseWriter, r *http.Request) {
	s.Music.ServeFile(w, r, chi.URLParam(r, "id"))
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
