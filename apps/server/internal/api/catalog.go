package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"soundflow/server/internal/acquire"
)

// GET /v1/search?q= — поиск по уже скачанному каталогу.
func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	limit := 50
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 200 {
		limit = v
	}
	list, err := s.DB.CatalogSearch(r.Context(), q, limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"tracks": list})
}

type acquireReq struct {
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	DurationSec int    `json:"duration_sec"`
}

// POST /v1/tracks/acquire — найти и скачать трек на fg, положить в каталог.
func (s *Server) acquireTrack(w http.ResponseWriter, r *http.Request) {
	var req acquireReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "битый json"})
		return
	}
	if req.Artist == "" || req.Title == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужны artist и title"})
		return
	}
	if s.Acquire == nil || s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "сервер не готов качать (нет базы или сайдкара)"})
		return
	}

	res, err := s.Acquire.Acquire(r.Context(), acquire.Request{
		Artist:              req.Artist,
		Title:               req.Title,
		ExpectedDurationSec: req.DurationSec,
	})
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, res)
	case errors.Is(err, acquire.ErrRejected):
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "отклонено", "reason": res.Reason})
	case errors.Is(err, acquire.ErrNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "не нашлось ни в одном источнике"})
	case errors.Is(err, acquire.ErrLowQuality):
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "плохое качество", "reason": res.Reason})
	default:
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
	}
}
