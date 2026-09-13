package main

import (
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
)

// «Обучение вкусу», этап 2 (docs/TASTE-PLAN.md): окно показывает, что
// программа поняла про вкус Alex — топ/антитоп исполнителей и треков из
// накопленных сигналов (лайки, пропуски, удаления). Оценки — суммы весов;
// декей, слои и кластеры — этапы дальше.

// GET /api/taste
func (s *Service) hTaste(w http.ResponseWriter, r *http.Request) {
	topA, botA, err := s.db.TasteArtists(15)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	topT, botT, err := s.db.TasteTracks(20)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	totals, err := s.db.TasteTotals()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	clusters, err := s.db.TasteClusters(4)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]any{
		"totals":         totals,
		"top_artists":    topA,
		"bottom_artists": botA,
		"top_tracks":     topT,
		"bottom_tracks":  botT,
		"clusters":       clusters,
	})
}

// POST /api/taste/rebuild — разово пересобрать сигналы вкуса из всей истории
// событий (для баз, где события копились до появления «вкуса») и следом
// пересчитать центры вкуса.
func (s *Service) hTasteRebuild(w http.ResponseWriter, r *http.Request) {
	n, err := s.db.RebuildFeedback()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	ncLong, ntLong, cerr := s.db.RecomputeTasteClusters("long_term", nil)
	if cerr != nil {
		http.Error(w, cerr.Error(), 500)
		return
	}
	cutoff := time.Now().AddDate(0, 0, -21)
	ncRecent, ntRecent, cerr := s.db.RecomputeTasteClusters("recent", &cutoff)
	if cerr != nil {
		http.Error(w, cerr.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "",
		"пересобран вкус: "+strconv.Itoa(n)+" сигналов, "+strconv.Itoa(ncLong)+" долгих центров по "+strconv.Itoa(ntLong)+" трекам, "+strconv.Itoa(ncRecent)+" недавних по "+strconv.Itoa(ntRecent), 0)
	writeJSON(w, map[string]any{
		"rows":      n,
		"long_term": map[string]int{"clusters": ncLong, "tracks": ntLong},
		"recent":    map[string]int{"clusters": ncRecent, "tracks": ntRecent},
	})
}

// GET /api/devices/{id}/suggest?n=30 — «Предлагаю по вкусу»: что скачать на
// это устройство. Список идёт в окно ручной синхронизации отдельной секцией
// с галочками (TASTE-PLAN §7 — не качаем молча).
func (s *Service) hSuggest(w http.ResponseWriter, r *http.Request) {
	dev := chi.URLParam(r, "id")
	if dev == "" {
		http.Error(w, "нужен id устройства", 400)
		return
	}
	n := atoiDef(r.URL.Query().Get("n"), 30)
	if n < 1 || n > 200 {
		n = 30
	}
	list, err := s.db.SuggestDownloads(dev, n)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, list)
}

// POST /api/taste/cluster — пересчитать только центры вкуса (по звуку).
func (s *Service) hTasteCluster(w http.ResponseWriter, r *http.Request) {
	ncLong, ntLong, err := s.db.RecomputeTasteClusters("long_term", nil)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	cutoff := time.Now().AddDate(0, 0, -21)
	ncRecent, ntRecent, err := s.db.RecomputeTasteClusters("recent", &cutoff)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "",
		"пересчитаны центры вкуса: "+strconv.Itoa(ncLong)+" долгих по "+strconv.Itoa(ntLong)+", "+strconv.Itoa(ncRecent)+" недавних по "+strconv.Itoa(ntRecent), 0)
	writeJSON(w, map[string]any{
		"long_term": map[string]int{"clusters": ncLong, "tracks": ntLong},
		"recent":    map[string]int{"clusters": ncRecent, "tracks": ntRecent},
	})
}
