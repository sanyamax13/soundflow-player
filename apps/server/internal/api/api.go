package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"soundflow/server/internal/auth"
	"soundflow/server/internal/db"
	"soundflow/server/internal/music"
)

type Server struct {
	Auth  *auth.Auth
	DB    *db.Pool
	Music *music.Service
}

func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(15 * time.Second))

	r.Route("/v1", func(r chi.Router) {
		r.Get("/health", s.health)
		r.Post("/auth/login", s.login)

		// Защищённая ветка — проверяет пропуск в заголовке Authorization.
		r.Group(func(r chi.Router) {
			r.Use(s.requireToken)
			r.Get("/me", s.me)
			r.Get("/tracks", s.tracks)
			r.Get("/music/{id}/file", s.musicFile)
		})
	})
	return r
}

func (s *Server) tracks(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"tracks": s.Music.List()})
}

func (s *Server) musicFile(w http.ResponseWriter, r *http.Request) {
	s.Music.ServeFile(w, r, chi.URLParam(r, "id"))
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

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Login    string `json:"login"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "ждём JSON {login, password}"})
		return
	}
	token, err := s.Auth.Login(body.Login, body.Password)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"token": token})
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	login, _ := r.Context().Value(ctxLogin).(string)
	writeJSON(w, http.StatusOK, map[string]string{"login": login})
}

type ctxKey string

const ctxLogin ctxKey = "login"

func (s *Server) requireToken(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		token := strings.TrimPrefix(h, "Bearer ")
		if token == "" || token == h {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "нужен заголовок Authorization: Bearer <пропуск>"})
			return
		}
		login, err := s.Auth.Verify(token)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "пропуск недействителен"})
			return
		}
		ctx := context.WithValue(r.Context(), ctxLogin, login)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
