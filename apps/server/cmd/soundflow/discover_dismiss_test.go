package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
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

// fakeSidecar — «качалка», отвечающая на /yandex/playlist заданным JSON; возвращает адрес ссылок, что ей пришли.
func fakeSidecar(t *testing.T, playlistJSON string) *[]string {
	t.Helper()
	var links []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/yandex/playlist" {
			links = append(links, r.URL.Query().Get("url"))
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(playlistJSON))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(srv.Close)
	t.Setenv("SOUNDFLOW_SIDECAR_URL", srv.URL)
	return &links
}

const testPlaylistLink = "https://music.yandex.ru/playlists/lk.9447495f-2bae-4887-b855-9d6e055770e3?utm_medium=copy_link"

func getPlaylist(e *ctxEnv, link string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	e.s.hYandexPlaylist(rec, httptest.NewRequest("GET", "/api/yandex/playlist?url="+url.QueryEscape(link), nil))
	return rec
}

func TestPlaylistHidesDismissedButKeepOnesInCatalog(t *testing.T) {
	e := ctxFixture(t)
	links := fakeSidecar(t, `{"title":"Мне нравится","items":[
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
	rec := getPlaylist(e, testPlaylistLink)
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	var out yandexPlaylistOut
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.Title != "Мне нравится" {
		t.Errorf("название плейлиста: %q", out.Title)
	}
	if len(*links) != 1 || (*links)[0] != testPlaylistLink {
		t.Errorf("качалке ушла не та ссылка: %v", *links)
	}
	names := map[string]bool{}
	for _, it := range out.Items {
		names[it.Artist] = it.AlreadyHave
	}
	if _, ok := names["Foo"]; ok {
		t.Error("скрытая «Foo — Bar» всё ещё в списке")
	}
	if _, ok := names["Baz"]; !ok {
		t.Error("нескрытая «Baz — Qux» пропала")
	}
	if have, ok := names["Own"]; !ok || !have {
		t.Error("песня, что уже в каталоге, не должна пропадать из списка из-за скрытия (она и так помечена «есть»)")
	}
}

// Плохая ссылка/закрытый плейлист — понятный текст качалки доходит до Alex как есть (400), а не «ошибка сервера».
func TestPlaylistErrorsAreReadable(t *testing.T) {
	e := ctxFixture(t)
	if rec := getPlaylist(e, "  "); rec.Code != 400 || !strings.Contains(rec.Body.String(), "Вставь ссылку") {
		t.Errorf("пустая ссылка: %d %q", rec.Code, rec.Body)
	}
	if rec := getPlaylist(e, strings.Repeat("a", maxPlaylistLink+1)); rec.Code != 400 {
		t.Errorf("слишком длинная ссылка: %d", rec.Code)
	}
	fakeSidecar(t, `{"title":"","items":[],"error":"Плейлист не открылся: ссылка устарела или плейлист закрыт"}`)
	if rec := getPlaylist(e, testPlaylistLink); rec.Code != 400 || !strings.Contains(rec.Body.String(), "ссылка устарела") {
		t.Errorf("отказ качалки должен дойти как есть: %d %q", rec.Code, rec.Body)
	}
}

// Качалка не отвечает — 502 (а не 400): это не вина ссылки.
func TestPlaylistSidecarDown(t *testing.T) {
	e := ctxFixture(t)
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()
	t.Setenv("SOUNDFLOW_SIDECAR_URL", dead.URL)
	if rec := getPlaylist(e, testPlaylistLink); rec.Code != 502 {
		t.Errorf("качалка не отвечает: ждал 502, получил %d %q", rec.Code, rec.Body)
	}
}

// Живые записи в «Волну» не пускаем (Alex TG 20133): ни свежую выборку, ни то, что уже лежит в кэше дня.
func TestWaveCachedBatchDropsLiveRecordings(t *testing.T) {
	e := ctxFixture(t)
	batch, _ := json.Marshal([]yandexWaveOut{
		{YandexID: "1", Artist: "Depeche Mode", Title: "Personal Jesus", Album: "Live In Frankfurt"},
		{YandexID: "2", Artist: "Depeche Mode", Title: "Enjoy The Silence", Album: "London 1993"},
		{YandexID: "3", Artist: "Depeche Mode", Title: "Enjoy The Silence (Live)", Album: "Violator"},
		{YandexID: "4", Artist: "Depeche Mode", Title: "Enjoy The Silence", Album: "Violator"},
		{YandexID: "5", Artist: "Various", Title: "Song", Album: "Best Of 2000"},
	})
	_ = e.s.db.SetSetting(settingWaveDate, waveDate(time.Now()))
	_ = e.s.db.SetSetting(settingWaveBatch, string(batch))
	rec := httptest.NewRecorder()
	e.s.hYandexWave(rec, httptest.NewRequest("GET", "/api/yandex/wave", nil))
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	var out []yandexWaveOut
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, it := range out {
		ids = append(ids, it.YandexID)
	}
	if strings.Join(ids, ",") != "4,5" {
		t.Errorf("в волне остались %v, ждали только студийные 4 и 5 (концерты 1–3 должны уйти)", ids)
	}
}

func TestWaveCachedBatchHidesDismissed(t *testing.T) {
	e := ctxFixture(t)
	batch, _ := json.Marshal([]yandexWaveOut{
		{YandexID: "1", Artist: "Foo", Title: "Bar"},
		{YandexID: "2", Artist: "Baz", Title: "Qux"},
	})
	_ = e.s.db.SetSetting(settingWaveDate, waveDate(time.Now()))
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
