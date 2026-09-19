package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/quality"
)

func postJSON(h http.HandlerFunc, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h(rec, httptest.NewRequest("POST", "/x", strings.NewReader(body)))
	return rec
}

func TestDiscoverDismissHandlers(t *testing.T) {
	e := ctxFixture(t)
	key := quality.NormalizedKey("Foo", "Bar")

	if rec := postJSON(e.s.hDiscoverDismiss, `{"artist":"Foo","title":"Bar"}`); rec.Code != 200 {
		t.Fatalf("dismiss: %d %s", rec.Code, rec.Body)
	}
	if got, _ := e.s.db.DismissedDiscover(); !got[key] {
		t.Fatalf("не скрылось: %v", got)
	}
	if rec := postJSON(e.s.hDiscoverUndismiss, `{"artist":"Foo","title":"Bar"}`); rec.Code != 200 {
		t.Fatalf("undismiss: %d %s", rec.Code, rec.Body)
	}
	if got, _ := e.s.db.DismissedDiscover(); got[key] {
		t.Fatalf("не вернулось: %v", got)
	}
	for _, bad := range []string{`не json`, `{}`, `{"artist":"","title":""}`} {
		if rec := postJSON(e.s.hDiscoverDismiss, bad); rec.Code != 400 {
			t.Errorf("%q: ждал 400, получил %d", bad, rec.Code)
		}
	}
}

// Ручки-команды — только с этого компьютера (как остальные, что меняют состояние).
func TestDiscoverRoutesAreLocalOnly(t *testing.T) {
	e := ctxFixture(t)
	h := localOnly(e.s.hDiscoverDismiss)
	req := httptest.NewRequest("POST", "/api/discover/dismiss", strings.NewReader(`{"artist":"A","title":"B"}`))
	req.RemoteAddr = "192.168.1.50:5555"
	rec := httptest.NewRecorder()
	h(rec, req)
	if rec.Code != 403 {
		t.Fatalf("чужой адрес: ждал 403, получил %d", rec.Code)
	}
	if got, _ := e.s.db.DismissedDiscover(); len(got) != 0 {
		t.Fatal("с чужого адреса ничего не должно скрываться")
	}
}

func fakeSidecar(t *testing.T, likesJSON string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/yandex/likes" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(likesJSON))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(srv.Close)
	t.Setenv("SOUNDFLOW_SIDECAR_URL", srv.URL)
}

func TestLikesHideDismissedButKeepOnesInCatalog(t *testing.T) {
	e := ctxFixture(t)
	fakeSidecar(t, `{"items":[
		{"yandex_id":"1","artist":"Foo","title":"Bar"},
		{"yandex_id":"2","artist":"Baz","title":"Qux"},
		{"yandex_id":"3","artist":"Own","title":"Song"}]}`)
	// «Own — Song» уже лежит в каталоге
	ownKey := quality.NormalizedKey("Own", "Song")
	if err := e.s.db.InsertTrackWithFile(
		localdb.NewTrack{ID: "t_own", Artist: "Own", Title: "Song", NormalizedKey: ownKey},
		localdb.NewTrackFile{ID: "f_own", NormalizedKey: ownKey, FilePath: e.root + `\own.mp3`}); err != nil {
		t.Fatal(err)
	}
	for _, k := range [][2]string{{"Foo", "Bar"}, {"Own", "Song"}} {
		if err := e.s.db.DismissDiscover(quality.NormalizedKey(k[0], k[1]), k[0], k[1]); err != nil {
			t.Fatal(err)
		}
	}
	rec := httptest.NewRecorder()
	e.s.hYandexLikes(rec, httptest.NewRequest("GET", "/api/yandex/likes", nil))
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	var out []yandexLikeOut
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, it := range out {
		names[it.Artist] = it.AlreadyHave
	}
	if _, ok := names["Foo"]; ok {
		t.Error("скрытая «Foo — Bar» всё ещё в списке лайков")
	}
	if _, ok := names["Baz"]; !ok {
		t.Error("нескрытая «Baz — Qux» пропала")
	}
	if have, ok := names["Own"]; !ok || !have {
		t.Error("песня, что уже в каталоге, не должна пропадать из лайков из-за скрытия (она и так помечена «есть»)")
	}
}

func TestWaveCachedBatchHidesDismissed(t *testing.T) {
	e := ctxFixture(t)
	batch, _ := json.Marshal([]yandexWaveOut{
		{YandexID: "1", Artist: "Foo", Title: "Bar"},
		{YandexID: "2", Artist: "Baz", Title: "Qux"},
	})
	_ = e.s.db.SetSetting(settingWaveDate, time.Now().UTC().Format("2006-01-02"))
	_ = e.s.db.SetSetting(settingWaveBatch, string(batch))
	if err := e.s.db.DismissDiscover(quality.NormalizedKey("Foo", "Bar"), "Foo", "Bar"); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	e.s.hYandexWave(rec, httptest.NewRequest("GET", "/api/yandex/wave", nil))
	var out []yandexWaveOut
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("%v: %s", err, rec.Body)
	}
	if len(out) != 1 || out[0].Artist != "Baz" {
		t.Fatalf("ждал только «Baz — Qux», получил %+v", out)
	}
}

func TestPhoneMissingFavoritesHideDismissed(t *testing.T) {
	e := ctxFixture(t)
	_ = e.s.db.ReportMissingFavorites([]localdb.MissingFavorite{
		{NormalizedKey: quality.NormalizedKey("Foo", "Bar"), Artist: "Foo", Title: "Bar"},
		{NormalizedKey: quality.NormalizedKey("Baz", "Qux"), Artist: "Baz", Title: "Qux"},
	})
	if err := e.s.db.DismissDiscover(quality.NormalizedKey("Foo", "Bar"), "Foo", "Bar"); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	e.s.hPhoneFavoritesMissing(rec, httptest.NewRequest("GET", "/api/phone/missing-favorites", nil))
	var out []missingFavoriteOut
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if len(out) != 1 || out[0].Artist != "Baz" {
		t.Fatalf("ждал только «Baz — Qux», получил %+v", out)
	}
}
