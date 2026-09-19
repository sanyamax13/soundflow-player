package localdb

import (
	"reflect"
	"testing"
)

func TestMergePlanKeepsExistingAndLastDecisionWins(t *testing.T) {
	d := open(t)
	// в плане уже лежит чужой невыполненный список — он не должен пропасть
	if err := d.SavePlan("dev1", []string{"a1"}, []string{"r1", "r2"}); err != nil {
		t.Fatal(err)
	}
	add, rem, err := d.MergePlan("dev1", []string{"a2", "r2"}, []string{"a1", "r3", "r3", ""})
	if err != nil {
		t.Fatal(err)
	}
	// r2 перешла из remove в add, a1 — из add в remove, r3 добавлена один раз
	gotAdd, gotRem, _, ok, err := d.Plan("dev1")
	if err != nil || !ok {
		t.Fatalf("план: ok=%v err=%v", ok, err)
	}
	if want := []string{"a2", "r2"}; !reflect.DeepEqual(gotAdd, want) {
		t.Errorf("add = %v, ждали %v", gotAdd, want)
	}
	if want := []string{"r1", "a1", "r3"}; !reflect.DeepEqual(gotRem, want) {
		t.Errorf("remove = %v, ждали %v", gotRem, want)
	}
	if add != 2 || rem != 3 {
		t.Errorf("счётчики %d/%d, ждали 2/3", add, rem)
	}
}

func TestMergePlanCreatesPlan(t *testing.T) {
	d := open(t)
	if _, _, err := d.MergePlan("devX", []string{"x"}, nil); err != nil {
		t.Fatal(err)
	}
	add, rem, _, ok, _ := d.Plan("devX")
	if !ok || !reflect.DeepEqual(add, []string{"x"}) || len(rem) != 0 {
		t.Errorf("план: ok=%v add=%v rem=%v", ok, add, rem)
	}
}

// Телефон стёр remove и отчитался: комп записывает «убрано» (delete, pc_removed) —
// песня больше не числится на телефоне, метки «больше не качать» НЕТ.
func TestClearPlanRecordsRemovalWithoutBlocking(t *testing.T) {
	d := open(t)
	addTrack(t, d, "t1", "Artist", []float32{1})
	if _, err := d.SaveSync(Device{ID: "dev1", Name: "phone"}, []SyncEvent{
		{UUID: "u-dl", Kind: "download", TrackID: "t1", ClientTS: 1},
	}); err != nil {
		t.Fatal(err)
	}
	have, _ := d.DeviceTrackIDs("dev1")
	if !have["t1"] {
		t.Fatalf("до плана t1 должна числиться на телефоне: %v", have)
	}
	if err := d.SavePlan("dev1", nil, []string{"t1"}); err != nil {
		t.Fatal(err)
	}
	if err := d.ClearPlan("dev1"); err != nil {
		t.Fatal(err)
	}
	have, _ = d.DeviceTrackIDs("dev1")
	if have["t1"] {
		t.Errorf("после ack t1 не должна числиться на телефоне: %v", have)
	}
	var n int
	_ = d.sql.QueryRow(`SELECT count(*) FROM legacy_marks WHERE kind='blocked'`).Scan(&n)
	if n != 0 {
		t.Errorf("метка blocked не должна ставиться, а стоит %d", n)
	}
	var fb int
	_ = d.sql.QueryRow(`SELECT count(*) FROM feedback_event`).Scan(&fb)
	if fb != 0 {
		t.Errorf("убрать с телефона — не сигнал вкуса, а записано %d", fb)
	}
	if _, _, _, ok, _ := d.Plan("dev1"); ok {
		t.Errorf("план должен быть снят")
	}
	// повторный ack без плана — не ошибка
	if err := d.ClearPlan("dev1"); err != nil {
		t.Errorf("ack без плана: %v", err)
	}
}

// «Докачать ещё» не возвращает то, что убрали из окна ПК, пока песню не
// добавили на телефон заново.
func TestNextLibraryBatchSkipsPcRemoved(t *testing.T) {
	d := open(t)
	addTrack(t, d, "keep", "A", []float32{1})
	addTrack(t, d, "gone", "B", []float32{1})
	if err := d.SavePlan("dev1", nil, []string{"gone"}); err != nil {
		t.Fatal(err)
	}
	if err := d.ClearPlan("dev1"); err != nil {
		t.Fatal(err)
	}
	list, _, err := d.NextLibraryBatch(nil, 1<<40)
	if err != nil {
		t.Fatal(err)
	}
	ids := map[string]bool{}
	for _, tr := range list {
		ids[tr.ID] = true
	}
	if !ids["keep"] || ids["gone"] {
		t.Errorf("в докачке ждали только keep, получили %v", ids)
	}
	// добавили обратно (телефон скачал → событие download позже) — снова доступна
	if _, err := d.SaveSync(Device{ID: "dev1", Name: "phone"}, []SyncEvent{
		{UUID: "u-dl2", Kind: "download", TrackID: "gone", ClientTS: 2},
	}); err != nil {
		t.Fatal(err)
	}
	removed, _ := d.pcRemovedIDs()
	if removed["gone"] {
		t.Errorf("после нового download песня больше не «убрана»: %v", removed)
	}
}

func TestLatestDevice(t *testing.T) {
	d := open(t)
	if _, _, _, ok, err := d.LatestDevice(); ok || err != nil {
		t.Fatalf("устройств нет: ok=%v err=%v", ok, err)
	}
	if _, err := d.sql.Exec(`INSERT INTO devices (id,name,last_sync_at,created_at) VALUES
		('old','Samsung','2026-09-08T11:59:40Z','2026-09-05T00:00:00Z'),
		('live','Samsung','2026-09-19T10:46:42Z','2026-09-13T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	id, _, _, ok, err := d.LatestDevice()
	if err != nil || !ok || id != "live" {
		t.Errorf("id=%q ok=%v err=%v, ждали live", id, ok, err)
	}
}
