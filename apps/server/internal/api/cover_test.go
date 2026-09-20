package api

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-chi/chi/v5"
)

func coverGet(s *Server, id string) *httptest.ResponseRecorder {
	r := chi.NewRouter()
	r.Get("/v1/cover/{id}", s.cover)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest("GET", "/v1/cover/"+id, nil))
	return rec
}

// Обложки нет нигде — 404 (телефон это проглатывает), как раньше.
func TestCoverNowhereIs404(t *testing.T) {
	st, pm, id, _, _ := gateFixture(t)
	if rec := coverGet(&Server{DB: st, PathMap: pm}, id); rec.Code != http.StatusNotFound {
		t.Fatalf("ждал 404, получил %d", rec.Code)
	}
}

// Alex TG 20146: у песни нет обложки в файле, но в папке альбома лежит cover.jpg — телефон получает её.
func TestCoverFromAlbumFolder(t *testing.T) {
	st, pm, id, local, _ := gateFixture(t)
	if err := os.WriteFile(filepath.Join(filepath.Dir(local), "cover.jpg"), []byte("folder-cover"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := coverGet(&Server{DB: st, PathMap: pm}, id)
	if rec.Code != http.StatusOK || rec.Body.String() != "folder-cover" {
		t.Fatalf("ждал 200 и картинку из папки, получил %d %q", rec.Code, rec.Body.String())
	}
}

// Найденная поиском обложка (<id>.jpg в папке найденных) — когда ни в файле, ни в папке альбома ничего нет.
func TestCoverFoundBySearch(t *testing.T) {
	st, pm, id, _, _ := gateFixture(t)
	found := t.TempDir()
	if err := os.WriteFile(filepath.Join(found, id+".jpg"), []byte("found-cover"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := coverGet(&Server{DB: st, PathMap: pm, FoundCoversDir: found}, id)
	if rec.Code != http.StatusOK || rec.Body.String() != "found-cover" {
		t.Fatalf("ждал 200 и найденную картинку, получил %d %q", rec.Code, rec.Body.String())
	}
}

// Картинка в папке альбома важнее найденной в сети: своя честнее чужой.
func TestCoverAlbumFolderBeatsFound(t *testing.T) {
	st, pm, id, local, _ := gateFixture(t)
	if err := os.WriteFile(filepath.Join(filepath.Dir(local), "folder.png"), []byte("own"), 0o644); err != nil {
		t.Fatal(err)
	}
	found := t.TempDir()
	if err := os.WriteFile(filepath.Join(found, id+".jpg"), []byte("found"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := coverGet(&Server{DB: st, PathMap: pm, FoundCoversDir: found}, id)
	if rec.Body.String() != "own" {
		t.Fatalf("ждал картинку из папки альбома, получил %q", rec.Body.String())
	}
}
