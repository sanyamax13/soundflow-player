package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"soundflow/server/internal/localdb"
)

func testService(t *testing.T) *Service {
	t.Helper()
	db, err := localdb.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return &Service{db: db}
}

func TestHCentroidsHashEmpty(t *testing.T) {
	s := testService(t)
	req := httptest.NewRequest(http.MethodGet, "/api/taste/centroids-hash", nil)
	w := httptest.NewRecorder()
	s.hCentroidsHash(w, req)
	if w.Code != 200 {
		t.Fatalf("status %d", w.Code)
	}
	var resp map[string]string
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	if resp["hash"] == "" {
		t.Error("expected a non-empty hash even with no clusters")
	}
}

func TestHTrackVectorsMissingIDSkipped(t *testing.T) {
	s := testService(t)
	v := make([]float32, localdb.VecDim)
	v[0] = 1
	if _, err := s.db.SQL().Exec(
		`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
		"real1", "A", "real1", "real1", localdb.VecToBlob(v)); err != nil {
		t.Fatal(err)
	}

	body := strings.NewReader(`{"ids":["real1","missing1"]}`)
	req := httptest.NewRequest(http.MethodPost, "/api/tracks/vectors", body)
	w := httptest.NewRecorder()
	s.hTrackVectors(w, req)
	if w.Code != 200 {
		t.Fatalf("status %d", w.Code)
	}
	var resp struct {
		Vectors map[string]string `json:"vectors"`
	}
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	if _, ok := resp.Vectors["real1"]; !ok {
		t.Error("expected real1 in response")
	}
	if _, ok := resp.Vectors["missing1"]; ok {
		t.Error("missing1 has no vector — should be omitted, not present")
	}
}
