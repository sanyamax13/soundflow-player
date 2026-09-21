package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"soundflow/server/internal/localdb"
)

func getPlan(t *testing.T, e *ctxEnv, query string) planResp {
	t.Helper()
	rec := httptest.NewRecorder()
	e.s.hPhonePlanGet(rec, httptest.NewRequest("GET", "/api/phone/plan"+query, nil))
	if rec.Code != 200 {
		t.Fatalf("GET plan: код %d: %s", rec.Code, rec.Body.String())
	}
	var out planResp
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestPhonePlanGetWithoutDeviceOrPlanIsEmpty(t *testing.T) {
	e := ctxFixture(t)
	p := getPlan(t, e, "")
	if p.HasPlan || p.Add == nil || p.Remove == nil || len(p.Add)+len(p.Remove) != 0 {
		t.Errorf("телефона нет: %+v", p)
	}
	if _, err := e.s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"}, nil); err != nil {
		t.Fatal(err)
	}
	p = getPlan(t, e, "")
	if p.HasPlan || p.DeviceID != "phone" || p.Device != "Samsung" {
		t.Errorf("телефон есть, плана нет: %+v", p)
	}
	// пустой план (обе части пусты) — тоже «плана нет»
	if err := e.s.db.SavePlan("phone", nil, nil); err != nil {
		t.Fatal(err)
	}
	if p = getPlan(t, e, ""); p.HasPlan {
		t.Errorf("пустой план должен считаться отсутствующим: %+v", p)
	}
}

func TestPhonePlanGetNamesBytesAndMissing(t *testing.T) {
	e := ctxFixture(t)
	e.addSong(t, "t1", "a.mp3", "12345")   // 5 байт
	e.addSong(t, "t2", "b.mp3", "1234567") // 7 байт
	e.addSong(t, "t3", "c.mp3", "123")     // 3 байта, «на телефоне», в плане на стирание
	if _, err := e.s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"}, nil); err != nil {
		t.Fatal(err)
	}
	if err := e.s.db.SavePlan("phone", []string{"t1", "t2", "нет-такой"}, []string{"t3", "давно-нет"}); err != nil {
		t.Fatal(err)
	}
	p := getPlan(t, e, "")
	if !p.HasPlan || p.At == "" || p.Device != "Samsung" {
		t.Fatalf("план не найден: %+v", p)
	}
	if p.AddCount != 3 || p.RemoveCount != 2 || p.AddBytes != 12 || p.RemoveBytes != 3 || p.MissingAdd != 1 || p.Truncated {
		t.Errorf("счётчики: %+v", p)
	}
	if len(p.Add) != 3 || p.Add[0].Artist != "Art t1" || p.Add[0].Title != "Title t1" || p.Add[0].SizeBytes != 5 {
		t.Errorf("названия add: %+v", p.Add)
	}
	if !p.Add[2].Missing || p.Add[2].ID != "нет-такой" {
		t.Errorf("песня, которой нет в каталоге, должна быть помечена: %+v", p.Add[2])
	}
	if len(p.Remove) != 2 || p.Remove[0].Title != "Title t3" || !p.Remove[1].Missing {
		t.Errorf("remove: %+v", p.Remove)
	}
}

func TestPhonePlanGetLimitCutsListsNotTotals(t *testing.T) {
	e := ctxFixture(t)
	ids := []string{}
	for _, id := range []string{"t1", "t2", "t3", "t4"} {
		e.addSong(t, id, id+".mp3", "1234")
		ids = append(ids, id)
	}
	if _, err := e.s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"}, nil); err != nil {
		t.Fatal(err)
	}
	if err := e.s.db.SavePlan("phone", ids, nil); err != nil {
		t.Fatal(err)
	}
	p := getPlan(t, e, "?limit=2")
	if len(p.Add) != 2 || p.AddCount != 4 || p.AddBytes != 16 || !p.Truncated {
		t.Errorf("limit=2: %+v", p)
	}
	p = getPlan(t, e, "?limit=0")
	if len(p.Add) != 0 || p.AddCount != 4 || !p.Truncated {
		t.Errorf("limit=0: %+v", p)
	}
}

// Отмена плана — не «телефон выполнил»: песни из remove на телефоне остаются, «убрано с телефона» не пишется.
func TestPhonePlanCancelKeepsPhoneContent(t *testing.T) {
	e := ctxFixture(t)
	e.addSong(t, "t1", "a.mp3", "12345")
	e.addSong(t, "t3", "c.mp3", "123")
	if _, err := e.s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"}, []localdb.SyncEvent{
		{UUID: "dl-t3", Kind: "download", TrackID: "t3", ClientTS: 1},
	}); err != nil {
		t.Fatal(err)
	}
	if err := e.s.db.SavePlan("phone", []string{"t1"}, []string{"t3"}); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	e.s.hPhonePlanCancel(rec, httptest.NewRequest("DELETE", "/api/phone/plan", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"cancelled":true`) ||
		!strings.Contains(rec.Body.String(), `"was_add":1`) || !strings.Contains(rec.Body.String(), `"was_remove":1`) {
		t.Fatalf("отмена: код %d %s", rec.Code, rec.Body.String())
	}
	if p := getPlan(t, e, ""); p.HasPlan {
		t.Errorf("план должен исчезнуть: %+v", p)
	}
	have, err := e.s.db.DeviceTrackIDs("phone")
	if err != nil {
		t.Fatal(err)
	}
	if !have["t3"] {
		t.Errorf("песня t3 осталась на телефоне, а по базе её «убрали»: %v", have)
	}

	// второй раз — плана уже нет
	rec = httptest.NewRecorder()
	e.s.hPhonePlanCancel(rec, httptest.NewRequest("DELETE", "/api/phone/plan", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"cancelled":false`) {
		t.Errorf("повторная отмена: код %d %s", rec.Code, rec.Body.String())
	}
}

// Для сравнения: «телефон выполнил» (ClearPlan) как раз пишет «убрано с телефона» — отмена так делать не должна.
func TestPhonePlanClearPlanRecordsRemovals(t *testing.T) {
	e := ctxFixture(t)
	e.addSong(t, "t3", "c.mp3", "123")
	if _, err := e.s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"}, []localdb.SyncEvent{
		{UUID: "dl-t3", Kind: "download", TrackID: "t3", ClientTS: 1},
	}); err != nil {
		t.Fatal(err)
	}
	if err := e.s.db.SavePlan("phone", nil, []string{"t3"}); err != nil {
		t.Fatal(err)
	}
	if err := e.s.db.ClearPlan("phone"); err != nil {
		t.Fatal(err)
	}
	have, _ := e.s.db.DeviceTrackIDs("phone")
	if have["t3"] {
		t.Fatalf("после ClearPlan песня должна считаться убранной: %v", have)
	}
}

func TestPhonePlanCancelWithoutDevice(t *testing.T) {
	e := ctxFixture(t)
	rec := httptest.NewRecorder()
	e.s.hPhonePlanCancel(rec, httptest.NewRequest("DELETE", "/api/phone/plan", nil))
	if rec.Code != http.StatusConflict {
		t.Errorf("телефона нет: ждали 409, получили %d", rec.Code)
	}
}
