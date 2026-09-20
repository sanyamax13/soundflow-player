package main

import (
	"strings"
	"testing"

	"soundflow/server/internal/localdb"
)

// Новая скачанная песня сама ложится в план телефона (Alex TG 20159), прежний план
// не затирается.
func TestAutoPlanAddPutsNewSongIntoPhonePlan(t *testing.T) {
	e := ctxFixture(t)
	if _, err := e.s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"}, nil); err != nil {
		t.Fatal(err)
	}
	if err := e.s.db.SavePlan("phone", []string{"a-old"}, []string{"r-old"}); err != nil {
		t.Fatal(err)
	}

	e.s.autoPlanAdd("t9")
	e.s.autoPlanAdd("t9") // повтор не двоит
	e.s.autoPlanAdd("")   // пустой id — ничего

	add, rem, _, ok, err := e.s.db.Plan("phone")
	if err != nil || !ok {
		t.Fatalf("план: ok=%v err=%v", ok, err)
	}
	if strings.Join(add, ",") != "a-old,t9" {
		t.Errorf("add ждали a-old,t9, получили %v", add)
	}
	if strings.Join(rem, ",") != "r-old" {
		t.Errorf("remove не должен пострадать: %v", rem)
	}
}

// Телефон ещё ни разу не заходил — тихо ничего не делаем (не падаем, плана не создаём).
func TestAutoPlanAddWithoutDeviceIsQuiet(t *testing.T) {
	e := ctxFixture(t)
	e.s.autoPlanAdd("t9")
	if _, _, _, ok, _ := e.s.db.Plan("phone"); ok {
		t.Errorf("плана быть не должно")
	}
}
