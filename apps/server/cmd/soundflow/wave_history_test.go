package main

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"soundflow/server/internal/quality"
)

func daysAgo(n int) string { return waveDate(time.Now().AddDate(0, 0, -n)) }

func getWaveDays(t *testing.T, e *ctxEnv) []waveDayInfo {
	t.Helper()
	rec := httptest.NewRecorder()
	e.s.hYandexWaveDays(rec, httptest.NewRequest("GET", "/api/yandex/wave/days", nil))
	var out []waveDayInfo
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &out) != nil {
		t.Fatalf("дни волны: код %d, %s", rec.Code, rec.Body.String())
	}
	return out
}

// «История предыдущих 3 дней» (Alex TG 20212/20214): вчерашний список не пропадает, когда собирают сегодняшний,
// и лежит под своей датой; день считается по времени компьютера.
func TestWaveTodaysListMovesToHistoryNextDay(t *testing.T) {
	e := ctxFixture(t)
	// «вчерашний» список остался в кэше от прошлого дня (так он лежал до истории — wave_date + wave_batch)
	buf, _ := json.Marshal([]yandexWaveOut{{YandexID: "y1", Artist: "Вчерашний", Title: "Трек"}})
	_ = e.s.db.SetSetting(settingWaveDate, daysAgo(1))
	_ = e.s.db.SetSetting(settingWaveBatch, string(buf))

	// до сборки сегодняшнего вчерашний уже виден как «Вчера»
	if code, out, body := getWave(e, "?day=1"); code != 200 || len(out) != 1 || out[0].YandexID != "y1" {
		t.Fatalf("вчерашний список должен быть виден до сборки нового: %d %s", code, body)
	}

	calls := waveSidecar(t, []yandexWaveOut{{YandexID: "t1", Artist: "Сегодняшний", Title: "Трек"}})
	if code, out, body := getWave(e, ""); code != 200 || len(out) != 1 || out[0].YandexID != "t1" || *calls != 1 {
		t.Fatalf("новый день — качалку спрашивают заново: %d %s, обращений %d", code, body, *calls)
	}
	if code, out, body := getWave(e, "?day=1"); code != 200 || len(out) != 1 || out[0].YandexID != "y1" {
		t.Errorf("после сборки нового дня вчерашний должен остаться в истории: %d %s", code, body)
	}
	if code, out, _ := getWave(e, "?day=0"); code != 200 || len(out) != 1 || out[0].YandexID != "t1" || *calls != 1 {
		t.Errorf("day=0 — это сегодня, кэш без обращения к качалке: %+v, обращений %d", out, *calls)
	}
}

// История не длиннее трёх прошлых дней; дни без списка пропускаются, метки — по календарным дням.
func TestWaveHistoryKeepsThreeDaysAndSkipsGaps(t *testing.T) {
	e := ctxFixture(t)
	item := func(id string) []yandexWaveOut {
		return []yandexWaveOut{{YandexID: id, Artist: "A" + id, Title: "T" + id}}
	}
	hist := []waveDay{
		{Date: daysAgo(3), Items: item("d3")},
		{Date: daysAgo(1), Items: item("d1")},
		{Date: daysAgo(6), Items: item("d6")}, // старше окна — при новой записи пропадёт
	}
	buf, _ := json.Marshal(hist)
	_ = e.s.db.SetSetting(settingWaveHistory, string(buf))
	e.s.saveWave(waveDate(time.Now()), item("today"))

	days := getWaveDays(t, e)
	if len(days) != 3 || days[0].Day != 0 || days[0].Label != "Сегодня" || days[1].Day != 1 || days[1].Label != "Вчера" ||
		days[2].Day != 3 || days[2].Label != "3 дня назад" {
		t.Fatalf("ждали Сегодня, Вчера, 3 дня назад (2 дня назад пропущен): %+v", days)
	}
	if _, out, _ := getWave(e, "?day=2"); len(out) != 0 {
		t.Errorf("за пропущенный день ждали пустой список: %+v", out)
	}
	if _, out, body := getWave(e, "?day=3"); len(out) != 1 || out[0].YandexID != "d3" {
		t.Errorf("день 3: %s", body)
	}
	raw, _, _ := e.s.db.GetSetting(settingWaveHistory)
	var stored []waveDay
	_ = json.Unmarshal([]byte(raw), &stored)
	for _, d := range stored {
		if d.Date == daysAgo(6) {
			t.Errorf("список старше трёх дней должен пропасть из истории: %+v", stored)
		}
	}
}

// Прошлый день при показе тоже чистится: что с тех пор попало в каталог или помечено «не качать», не предлагается.
func TestWaveHistoryDayIsFilteredOnShow(t *testing.T) {
	e := ctxFixture(t)
	buf, _ := json.Marshal([]waveDay{{Date: daysAgo(2), Items: []yandexWaveOut{
		{YandexID: "1", Artist: "Убранный", Title: "Из списка"},
		{YandexID: "2", Artist: "Живой", Title: "Трек (Live)", Album: "Live in Paris"},
		{YandexID: "3", Artist: "Новый", Title: "Трек"},
	}}})
	_ = e.s.db.SetSetting(settingWaveHistory, string(buf))
	if err := e.s.db.DismissDiscover(quality.NormalizedKey("Убранный", "Из списка"), "Убранный", "Из списка"); err != nil {
		t.Fatal(err)
	}
	if code, out, body := getWave(e, "?day=2"); code != 200 || len(out) != 1 || out[0].YandexID != "3" {
		t.Fatalf("ждали одну новую песню: %d %s", code, body)
	}
}

func TestWaveDayParamIsChecked(t *testing.T) {
	e := ctxFixture(t)
	for _, q := range []string{"?day=4", "?day=-1", "?day=abc"} {
		if code, _, _ := getWave(e, q); code != 400 {
			t.Errorf("%s: ждали 400, получили %d", q, code)
		}
	}
	// прошлый день никогда не будит качалку
	calls := waveSidecar(t, nil)
	getWave(e, "?day=1&refresh=1")
	if *calls != 0 {
		t.Errorf("прошлый день не должен пересобираться, обращений %d", *calls)
	}
}

// Программа сама собирает подборку с waveAutoHour, если её ещё нет; раньше срока и при готовом списке — не трогает.
func TestWaveDailyBuildsByItself(t *testing.T) {
	e := ctxFixture(t)
	calls := waveSidecar(t, []yandexWaveOut{{YandexID: "auto", Artist: "Сам", Title: "Собрал"}})
	morning := time.Date(2026, 9, 21, waveAutoHour, 30, 0, 0, time.Local)

	e.s.waveDailyOnce(context.Background(), morning.Add(-time.Hour))
	if *calls != 0 {
		t.Fatalf("раньше waveAutoHour не собираем, обращений %d", *calls)
	}
	e.s.waveDailyOnce(context.Background(), morning)
	if *calls != 1 {
		t.Fatalf("в срок ждали одну сборку, обращений %d", *calls)
	}
	if date, _, _ := e.s.db.GetSetting(settingWaveDate); date != waveDate(morning) {
		t.Errorf("день списка %q, ждали %q", date, waveDate(morning))
	}
	e.s.waveDailyOnce(context.Background(), morning.Add(2*time.Hour))
	if *calls != 1 {
		t.Errorf("список за день уже есть — второй раз не собираем, обращений %d", *calls)
	}
	next := morning.AddDate(0, 0, 1)
	e.s.waveDailyOnce(context.Background(), next)
	if *calls != 2 {
		t.Errorf("новый день — новая сборка, обращений %d", *calls)
	}
	days := e.s.loadWaveDays()
	if len(days[waveDate(morning)]) != 1 || len(days[waveDate(next)]) != 1 {
		t.Errorf("вчерашний должен уйти в историю, сегодняшний — в кэш: %+v", days)
	}
}
