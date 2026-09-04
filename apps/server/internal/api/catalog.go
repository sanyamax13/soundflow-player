package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"

	"soundflow/server/internal/acquire"
	"soundflow/server/internal/importer"
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

type nextBatchReq struct {
	ExcludeIDs  []string `json:"exclude_ids"`
	BudgetBytes int64    `json:"budget_bytes"`
}

// POST /v1/library/next-batch — «докачать ещё»: телефон шлёт id того, что уже
// скачано, и бюджет в байтах; сервер отдаёт следующую порцию (избранное
// вперёд), пока не наберётся бюджет.
func (s *Server) libraryNextBatch(w http.ResponseWriter, r *http.Request) {
	var req nextBatchReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "битый json"})
		return
	}
	if req.BudgetBytes <= 0 {
		req.BudgetBytes = 20 << 30 // 20 ГБ по умолчанию
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	list, total, err := s.DB.NextLibraryBatch(r.Context(), req.ExcludeIDs, req.BudgetBytes)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"tracks": list, "total_bytes": total})
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

// importRunning — не даём двум обходам библиотеки идти параллельно (файлов
// много, смысла нет, а гонка на INSERT/UPDATE в базе не нужна).
var importRunning atomic.Bool

// POST /v1/admin/import-library — разово занести уже скачанную старым
// приложением музыку (D:\SoundFlow\cache, D:\SoundFlow\music) в новый
// каталог. Файлы читаем на месте, никуда не качаем и не двигаем. Долго
// (тысячи файлов) — работает фоном, прогресс смотреть в логе сервера или
// по счётчику каталога в /v1/admin/status.
func (s *Server) adminImportLibrary(w http.ResponseWriter, r *http.Request) {
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	roots := s.PathMap.LocalRoots()
	if len(roots) == 0 {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "не настроены пути библиотеки (SIDECAR_LOCAL_*_DIR)"})
		return
	}
	if !importRunning.CompareAndSwap(false, true) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "перенос уже идёт"})
		return
	}
	go func() {
		defer importRunning.Store(false)
		start := time.Now()
		res, err := importer.Scan(context.Background(), s.DB, s.PathMap, roots)
		if err != nil {
			log.Printf("import-library: остановлен ошибкой: %v (успело: %+v)", err, res)
			return
		}
		log.Printf("import-library: готово за %s — %+v", time.Since(start).Round(time.Second), res)
	}()
	writeJSON(w, http.StatusAccepted, map[string]any{"started": true, "roots": roots})
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
