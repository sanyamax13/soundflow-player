package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

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
		if res.Created {
			// «Звуковой отпечаток» считаем фоном — не держим ответ телефону
			// лишние секунды. Догон пропущенного — /v1/admin/reanalyze.
			go func(id string) {
				bg, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
				defer cancel()
				if e := s.Acquire.AnalyzeAndStore(bg, id); e != nil {
					log.Printf("анализ звука %s: %v", id, e)
				}
			}(res.TrackID)
		}
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

type streamOrderReq struct {
	SeedID       string   `json:"seed_id"`
	CandidateIDs []string `json:"candidate_ids"`
}

// POST /v1/stream/order — упорядочить очередь Потока по близости звучания к
// seed. Телефон шлёт id всех скачанных треков, получает их же в новом порядке.
func (s *Server) streamOrder(w http.ResponseWriter, r *http.Request) {
	var req streamOrderReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "битый json"})
		return
	}
	if req.SeedID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен seed_id"})
		return
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	ordered, err := s.DB.OrderBySimilarity(r.Context(), req.SeedID, req.CandidateIDs)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"track_ids": ordered})
}

// POST /v1/admin/reanalyze — досчитать «звуковой отпечаток» трекам, у которых
// его нет (после переноса каталога, сбоев сайдкара). Работает фоном.
func (s *Server) adminReanalyze(w http.ResponseWriter, r *http.Request) {
	if s.Acquire == nil || s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "сервер не готов"})
		return
	}
	ids, err := s.DB.TrackIDsWithoutFeatures(r.Context(), 500)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if len(ids) > 0 {
		go func(ids []string) {
			for _, id := range ids {
				bg, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
				if e := s.Acquire.AnalyzeAndStore(bg, id); e != nil {
					log.Printf("reanalyze %s: %v", id, e)
				}
				cancel()
			}
			log.Printf("reanalyze: обработано %d трек(ов)", len(ids))
		}(ids)
	}
	writeJSON(w, http.StatusOK, map[string]any{"queued": len(ids)})
}
