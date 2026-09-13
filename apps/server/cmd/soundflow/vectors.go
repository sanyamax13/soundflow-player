package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"

	"soundflow/server/internal/localdb"
)

// Ручки телефона для трёхслойного вкуса и офлайн-отпечатков (docs/TASTE-PLAN.md,
// docs/superpowers/specs/2026-09-13-taste-layers-offline-design.md §3.6).
// Сознательно МИМО internal/api — вызывают s.db напрямую, по образцу
// /api/taste/rebuild в taste.go. internal/api.Store имеет вторую реализацию
// на Postgres (мёртвый cmd/soundflow-server) — заводить туда эти методы
// незачем.

// GET /api/taste/centroids-hash — телефон дёргает после каждой синхронизации;
// если хэш отличается от сохранённого локально, тянет полный /api/taste/centroids.
func (s *Service) hCentroidsHash(w http.ResponseWriter, r *http.Request) {
	hash, err := s.db.TasteCentroidsHash()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]string{"hash": hash})
}

// GET /api/taste/centroids — центры long_term+recent, base64.
func (s *Service) hCentroids(w http.ResponseWriter, r *http.Request) {
	hash, err := s.db.TasteCentroidsHash()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	long, err := s.db.TasteCentroidsLayerBlobs("long_term")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	recent, err := s.db.TasteCentroidsLayerBlobs("recent")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]any{"hash": hash, "long_term": long, "recent": recent})
}

// POST /api/tracks/vectors {"ids": [...]} — отпечатки для пачки id
// (телефон дёргает сразу после скачивания трека и при бэкфилле старых).
func (s *Service) hTrackVectors(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad json", 400)
		return
	}
	out := map[string]string{}
	for _, id := range req.IDs {
		v, ok, err := s.db.FeatureVector(id)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		if !ok {
			continue
		}
		out[id] = base64.StdEncoding.EncodeToString(localdb.VecToBlob(v))
	}
	writeJSON(w, map[string]any{"vectors": out})
}
