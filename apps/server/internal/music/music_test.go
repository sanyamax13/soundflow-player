package music

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestListFallsBackToTestTone(t *testing.T) {
	got := New("").List()
	if len(got) != 1 || got[0].ID != "test-tone" {
		t.Fatalf("ждали один трек test-tone, получили %+v", got)
	}
}

func TestServeFileReturnsWav(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/music/test-tone/file", nil)
	New("").ServeFile(rec, req, "test-tone")

	if rec.Code != http.StatusOK {
		t.Fatalf("код %d", rec.Code)
	}
	body := rec.Body.Bytes()
	if !bytes.HasPrefix(body, []byte("RIFF")) || !bytes.Contains(body[:16], []byte("WAVE")) {
		t.Fatalf("не WAV: первые байты %q", body[:12])
	}
	if len(body) < 44+1000 {
		t.Fatalf("подозрительно короткий файл: %d байт", len(body))
	}
}

func TestServeFileRangeSupported(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/music/test-tone/file", nil)
	req.Header.Set("Range", "bytes=0-99")
	New("").ServeFile(rec, req, "test-tone")

	if rec.Code != http.StatusPartialContent {
		t.Fatalf("ждали 206 на Range, получили %d", rec.Code)
	}
	if rec.Body.Len() != 100 {
		t.Fatalf("ждали 100 байт, получили %d", rec.Body.Len())
	}
}
