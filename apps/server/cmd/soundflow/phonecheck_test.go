package main

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"soundflow/server/internal/localdb"
)

// phoneFixture — три песни компьютера с файлом (a, b, c), одна без файла (d); телефон «phone» зарегистрирован.
func phoneFixture(t *testing.T) *ctxEnv {
	t.Helper()
	e := ctxFixture(t)
	e.addSong(t, "a", "Папка/a.mp3", "aaaa")
	e.addSong(t, "b", "Папка/b.mp3", "bbbbbb")
	e.addSong(t, "c", "Папка/c.mp3", "cc")
	e.addSong(t, "d", "Папка/d.mp3", "") // запись есть, файла нет
	if _, err := e.s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"}, nil); err != nil {
		t.Fatal(err)
	}
	return e
}

func inventory(t *testing.T, e *ctxEnv, items ...localdb.InventoryItem) {
	t.Helper()
	if err := e.s.db.SavePhoneInventory("phone", items); err != nil {
		t.Fatal(err)
	}
}

func item(id string, size int64) localdb.InventoryItem {
	return localdb.InventoryItem{ID: id, Bytes: size}
}

// Что там и там, что только на телефоне (в том числе песня без файла у компьютера и чужая), что только у компьютера.
func TestPhoneCheckCounts(t *testing.T) {
	e := phoneFixture(t)
	inventory(t, e, item("a", 4), item("b", 6), item("x", 100), item("d", 50))

	chk, dev, add, remove, err := e.s.comparePhone(true)
	if err != nil {
		t.Fatal(err)
	}
	if dev != "phone" || !chk.HasPhone || !chk.Exact || chk.Stale {
		t.Fatalf("устройство и список: %+v", chk)
	}
	if chk.Phone != 4 || chk.PhoneBytes != 160 || chk.PC != 3 || chk.PCBytes != 12 || chk.Both != 2 {
		t.Errorf("числа: %+v", chk)
	}
	if chk.OnlyPhone != 2 || chk.OnlyPhoneBytes != 150 || chk.OnlyPC != 1 || chk.OnlyPCBytes != 2 {
		t.Errorf("расхождения: %+v", chk)
	}
	if strings.Join(add, ",") != "c" || strings.Join(remove, ",") != "d,x" {
		t.Errorf("списки для плана: add=%v remove=%v", add, remove)
	}
	if chk.Even || !chk.CanAlign || chk.Why != "" {
		t.Errorf("не ровно, выровнять можно: %+v", chk)
	}

	// когда совпало — «ровно»
	inventory(t, e, item("a", 4), item("b", 6), item("c", 2))
	chk, _, add, remove, _ = e.s.comparePhone(true)
	if !chk.Even || chk.CanAlign || chk.Why != "уже ровно" || len(add)+len(remove) != 0 || chk.Both != 3 {
		t.Errorf("ровно: %+v", chk)
	}
}

// Списка от телефона нет — считаем по журналу событий, но честно помечаем «неточно» и выравнивать не даём.
func TestPhoneCheckWithoutInventoryIsApproximate(t *testing.T) {
	e := phoneFixture(t)
	if _, err := e.s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"},
		[]localdb.SyncEvent{{UUID: "dl-a", Kind: "download", TrackID: "a", ClientTS: 1}}); err != nil {
		t.Fatal(err)
	}
	chk, _, _, _, err := e.s.comparePhone(true)
	if err != nil {
		t.Fatal(err)
	}
	if chk.Exact || chk.Phone != 1 || chk.CanAlign || !strings.Contains(chk.Why, "точный список") {
		t.Errorf("по журналу: %+v", chk)
	}
}

// Список старше 12 часов — устарел, выравнивать нельзя.
func TestPhoneCheckStaleListBlocksAlign(t *testing.T) {
	e := phoneFixture(t)
	inventory(t, e, item("a", 4))
	old := time.Now().Add(-13 * time.Hour).UTC().Format(time.RFC3339)
	if _, err := e.s.db.SQL().Exec(`UPDATE phone_inventory_meta SET at = ? WHERE device_id = 'phone'`, old); err != nil {
		t.Fatal(err)
	}
	chk, _, _, _, _ := e.s.comparePhone(true)
	if !chk.Stale || chk.CanAlign || !strings.Contains(chk.Why, "устарел") {
		t.Errorf("устаревший список: %+v", chk)
	}
}

// Пока песни едут с телефона на компьютер, выравнивать нельзя: иначе план стёр бы с телефона то, что ещё не вернулось.
func TestPhoneAlignBlockedWhileRestoring(t *testing.T) {
	e := phoneFixture(t)
	addDeadSong(t, e, "x", "Сборник/x.mp3", 100)
	e.s.db.SQL().Exec(`DELETE FROM track_files WHERE id = 'f_x'`) // как после уборки: записи файла нет
	if _, err := e.s.db.AddRestoreRequests([]localdb.RestoreRow{{TrackID: "x", FileID: "f_x", Path: "p", Size: 100}}); err != nil {
		t.Fatal(err)
	}
	inventory(t, e, item("a", 4), item("x", 100))

	chk, _, _, remove, _ := e.s.comparePhone(true)
	if chk.Arriving != 1 || chk.Restoring != 1 || chk.OnlyPhone != 0 || len(remove) != 0 {
		t.Errorf("«едет» не считается лишним: %+v remove=%v", chk, remove)
	}
	if chk.CanAlign || !strings.Contains(chk.Why, "едут") {
		t.Errorf("выравнивать нельзя: %+v", chk)
	}
	rec := httptest.NewRecorder()
	e.s.hPhoneAlign(rec, httptest.NewRequest("POST", "/api/phone/align", nil))
	if rec.Code != 409 {
		t.Errorf("align во время возврата: %d %s", rec.Code, rec.Body.String())
	}
	if _, _, _, ok, _ := e.s.db.Plan("phone"); ok {
		t.Error("план не должен появиться")
	}
}

// «Выровнять» кладёт в план телефона +добавить и −стереть, не затирая то, что в плане уже лежало.
func TestPhoneAlignMergesPlan(t *testing.T) {
	e := phoneFixture(t)
	inventory(t, e, item("a", 4), item("b", 6), item("x", 100))
	if err := e.s.db.SavePlan("phone", []string{"z-old"}, []string{"r-old"}); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	e.s.hPhoneAlign(rec, httptest.NewRequest("POST", "/api/phone/align", nil))
	if rec.Code != 200 {
		t.Fatalf("align: %d %s", rec.Code, rec.Body.String())
	}
	var got map[string]float64
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || got["add"] != 1 || got["remove"] != 1 || got["remove_bytes"] != 100 {
		t.Fatalf("ответ: %s", rec.Body.String())
	}
	add, remove, _, ok, err := e.s.db.Plan("phone")
	if err != nil || !ok {
		t.Fatalf("плана нет: %v", err)
	}
	if strings.Join(sortedCopy(add), ",") != "c,z-old" || strings.Join(sortedCopy(remove), ",") != "r-old,x" {
		t.Errorf("план: add=%v remove=%v", add, remove)
	}
	if !logHas(t, e, "сверка телефона с компьютером") {
		t.Error("в журнале нет записи о выравнивании")
	}
}

func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	for i := range out {
		for j := i + 1; j < len(out); j++ {
			if out[j] < out[i] {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}

// Песню, которую Alex сам убрал с телефона из окна, выравнивание обратно не добавляет; «не качать» — тоже.
func TestPhoneCheckDoesNotReAddRemovedOrBlocked(t *testing.T) {
	e := phoneFixture(t)
	blockSong(t, e, "b")
	if _, err := e.s.db.SQL().Exec(`INSERT INTO sync_events (event_uuid,device_id,kind,track_id,payload,client_ts,applied_at)
		VALUES ('pc-1','phone','delete','c','{"reason":"pc_removed"}',1,'2026-09-21T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	inventory(t, e, item("a", 4))

	chk, _, add, _, _ := e.s.comparePhone(true)
	if len(add) != 0 || chk.OnlyPC != 0 || chk.Removed != 1 || chk.PC != 2 {
		t.Errorf("c убрана самим Alex, b «не качать»: %+v add=%v", chk, add)
	}
	if !chk.Even {
		t.Errorf("сверка должна считаться ровной: %+v", chk)
	}
}

// Диск с музыкой недоступен — песни с него считаются «есть на компьютере», телефон не превращается в «лишнее».
func TestPhoneCheckUnavailableDiskIsNotMassRemoval(t *testing.T) {
	e := phoneFixture(t)
	key := "art far__title far"
	if err := e.s.db.InsertTrackWithFile(
		localdb.NewTrack{ID: "far", Artist: "Art far", Title: "Title far", NormalizedKey: key},
		localdb.NewTrackFile{ID: "f_far", NormalizedKey: key, FilePath: `Z:\нет-такого-диска\far.mp3`, SizeBytes: 777}); err != nil {
		t.Fatal(err)
	}
	inventory(t, e, item("a", 4), item("far", 777))

	chk, _, _, remove, _ := e.s.comparePhone(true)
	if chk.OnlyPhone != 0 || len(remove) != 0 || chk.Both != 2 {
		t.Errorf("песня с недоступного диска не «лишняя»: %+v remove=%v", chk, remove)
	}
}

// Телефон присылает список: неизвестное устройство отклоняется, известное — список записывается целиком (заменяя прежний).
func TestPhoneInventoryEndpoint(t *testing.T) {
	e := phoneFixture(t)
	post := func(body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		e.s.hPhoneInventory(rec, httptest.NewRequest("POST", "/api/phone/inventory", strings.NewReader(body)))
		return rec
	}
	if rec := post(`{"device_id":"nobody","items":[{"id":"a","b":1}]}`); rec.Code != 409 {
		t.Errorf("неизвестное устройство: %d", rec.Code)
	}
	if rec := post(`не json`); rec.Code != 400 {
		t.Errorf("мусор: %d", rec.Code)
	}
	if rec := post(`{"device_id":"phone","items":[{"id":"a","b":4},{"id":"b","b":6},{"id":"a","b":4},{"id":"","b":1}]}`); rec.Code != 200 {
		t.Fatalf("список: %d %s", rec.Code, rec.Body.String())
	}
	inv, at, ok, err := e.s.db.PhoneInventory("phone")
	if err != nil || !ok || len(inv) != 2 || inv["b"] != 6 || at == "" {
		t.Fatalf("сохранено: %v %v %v %q", inv, ok, err, at)
	}
	post(`{"device_id":"phone","items":[{"id":"c","b":2}]}`)
	if inv, _, _, _ = e.s.db.PhoneInventory("phone"); len(inv) != 1 || inv["c"] != 2 {
		t.Errorf("новый список должен заменить прежний: %v", inv)
	}

	rec := httptest.NewRecorder()
	e.s.hPhoneCheck(rec, httptest.NewRequest("GET", "/api/phone/check", nil))
	var chk phoneCheck
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &chk) != nil || !chk.Exact || chk.Phone != 1 {
		t.Errorf("check: %d %s", rec.Code, rec.Body.String())
	}
}

// Телефона в списке устройств ещё нет — окно ничего не показывает, ошибки нет.
func TestPhoneCheckNoDevice(t *testing.T) {
	e := ctxFixture(t)
	rec := httptest.NewRecorder()
	e.s.hPhoneCheck(rec, httptest.NewRequest("GET", "/api/phone/check", nil))
	var chk phoneCheck
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &chk) != nil || chk.HasPhone || chk.CanAlign {
		t.Errorf("без телефона: %d %s", rec.Code, rec.Body.String())
	}
}
