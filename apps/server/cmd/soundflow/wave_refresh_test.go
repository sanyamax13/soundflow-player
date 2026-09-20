package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// waveSidecar — качалка, отдающая «Волне» заданных кандидатов; calls считает, сколько раз её спросили.
func waveSidecar(t *testing.T, items []yandexWaveOut) *int {
	t.Helper()
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/yandex/wave-candidates" {
			http.NotFound(w, r)
			return
		}
		calls++
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
	}))
	t.Cleanup(srv.Close)
	t.Setenv("SOUNDFLOW_SIDECAR_URL", srv.URL)
	return &calls
}

func getWave(e *ctxEnv, query string) (int, []yandexWaveOut, string) {
	rec := httptest.NewRecorder()
	e.s.hYandexWave(rec, httptest.NewRequest("GET", "/api/yandex/wave"+query, nil))
	var out []yandexWaveOut
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out, rec.Body.String()
}

func cacheWave(t *testing.T, e *ctxEnv, items ...yandexWaveOut) {
	t.Helper()
	buf, _ := json.Marshal(items)
	_ = e.s.db.SetSetting(settingWaveDate, waveDate(time.Now()))
	_ = e.s.db.SetSetting(settingWaveBatch, string(buf))
}

// «Пересобрать волну» (Alex TG 20208): с ?refresh=1 качалку спрашивают заново и отдают новый список,
// обычный запрос после этого берёт уже новый кэш дня; без refresh кэш дня качалку не будит.
func TestWaveRefreshRebuildsPastTodaysCache(t *testing.T) {
	e := ctxFixture(t)
	cacheWave(t, e, yandexWaveOut{YandexID: "old", Artist: "Old Artist", Title: "Old Song"})
	calls := waveSidecar(t, []yandexWaveOut{{YandexID: "new", Artist: "New Artist", Title: "New Song"}})

	if code, out, _ := getWave(e, ""); code != 200 || len(out) != 1 || out[0].YandexID != "old" || *calls != 0 {
		t.Fatalf("без refresh ждали кэш дня без обращения к качалке: код %d, %+v, обращений %d", code, out, *calls)
	}
	code, out, body := getWave(e, "?refresh=1")
	if code != 200 || len(out) != 1 || out[0].YandexID != "new" || *calls != 1 {
		t.Fatalf("с refresh ждали новый список из качалки: код %d, %s, обращений %d", code, body, *calls)
	}
	if code, out, _ := getWave(e, ""); code != 200 || len(out) != 1 || out[0].YandexID != "new" || *calls != 1 {
		t.Errorf("после пересборки кэш дня должен быть новым и качалку не будить: %+v, обращений %d", out, *calls)
	}
}

// Не вышло пересобрать (качалка молчит) — прежний список остаётся как был.
func TestWaveRefreshFailureKeepsOldList(t *testing.T) {
	e := ctxFixture(t)
	cacheWave(t, e, yandexWaveOut{YandexID: "old", Artist: "Old Artist", Title: "Old Song"})
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()
	t.Setenv("SOUNDFLOW_SIDECAR_URL", dead.URL)

	if code, _, body := getWave(e, "?refresh=1"); code != 502 {
		t.Fatalf("качалка молчит: ждали 502, получили %d %s", code, body)
	}
	if code, out, _ := getWave(e, ""); code != 200 || len(out) != 1 || out[0].YandexID != "old" {
		t.Errorf("прежний список должен остаться: %d %+v", code, out)
	}
}

// Пока идёт одна пересборка, вторая не запускается (минута работы, лишние запросы к Яндексу).
func TestWaveRefreshWhileRebuildingIsRefused(t *testing.T) {
	e := ctxFixture(t)
	calls := waveSidecar(t, []yandexWaveOut{{YandexID: "new", Artist: "A", Title: "B"}})
	e.s.waveMu.Lock()
	code, _, body := getWave(e, "?refresh=1")
	e.s.waveMu.Unlock()
	if code != 409 || !strings.Contains(body, "пересобирается") || *calls != 0 {
		t.Errorf("ждали 409 без обращения к качалке: %d %q, обращений %d", code, body, *calls)
	}
}
