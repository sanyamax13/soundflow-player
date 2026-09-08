package main

import (
	"net/http"
	"strconv"
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
	nc, nt, cerr := s.db.RecomputeTasteClusters()
	if cerr != nil {
		http.Error(w, cerr.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "",
		"пересобран вкус: "+strconv.Itoa(n)+" сигналов, "+strconv.Itoa(nc)+" центров по "+strconv.Itoa(nt)+" трекам", 0)
	writeJSON(w, map[string]any{"rows": n, "clusters": nc, "cluster_tracks": nt})
}

// POST /api/taste/cluster — пересчитать только центры вкуса (по звуку).
func (s *Service) hTasteCluster(w http.ResponseWriter, r *http.Request) {
	nc, nt, err := s.db.RecomputeTasteClusters()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "",
		"пересчитаны центры вкуса: "+strconv.Itoa(nc)+" по "+strconv.Itoa(nt)+" трекам", 0)
	writeJSON(w, map[string]any{"clusters": nc, "cluster_tracks": nt})
}
