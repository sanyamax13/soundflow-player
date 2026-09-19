package localdb

import "testing"

func TestPendingRemovalsRoundTrip(t *testing.T) {
	d := open(t)

	got, err := d.PendingRemovals()
	if err != nil || len(got) != 0 {
		t.Fatalf("пустая таблица: %v %v", got, err)
	}

	a := PendingRemoval{TrackID: "t1", Artist: "A", Title: "One", FilePath: `E:\canon\one.mp3`, Bytes: 100, Reason: "dislike", AddedAt: "2026-09-19T01:00:00Z"}
	b := PendingRemoval{TrackID: "t2", Artist: "B", Title: "Two", FilePath: `E:\canon\two.mp3`, Bytes: 200, Reason: "", AddedAt: "2026-09-19T02:00:00Z"}
	for _, p := range []PendingRemoval{b, a} {
		if err := d.AddPendingRemoval(p); err != nil {
			t.Fatalf("add %s: %v", p.TrackID, err)
		}
	}
	// повтор того же трека не меняет запись
	dup := a
	dup.Bytes = 999
	if err := d.AddPendingRemoval(dup); err != nil {
		t.Fatalf("add dup: %v", err)
	}

	got, err = d.PendingRemovals()
	if err != nil || len(got) != 2 {
		t.Fatalf("ждал 2 записи, получил %v %v", got, err)
	}
	if got[0].TrackID != "t1" || got[1].TrackID != "t2" {
		t.Errorf("порядок: старые сверху, получил %s, %s", got[0].TrackID, got[1].TrackID)
	}
	if got[0].Bytes != 100 {
		t.Errorf("повтор не должен менять запись: bytes=%d", got[0].Bytes)
	}

	one, ok, err := d.PendingRemoval("t1")
	if err != nil || !ok || one.FilePath != `E:\canon\one.mp3` || one.Reason != "dislike" {
		t.Fatalf("PendingRemoval t1: %+v %v %v", one, ok, err)
	}
	if _, ok, _ := d.PendingRemoval("nope"); ok {
		t.Error("несуществующая запись не должна находиться")
	}

	if err := d.DeletePendingRemoval("t1"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	got, _ = d.PendingRemovals()
	if len(got) != 1 || got[0].TrackID != "t2" {
		t.Errorf("после удаления t1 остаётся t2, получил %v", got)
	}
	if err := d.AddPendingRemoval(PendingRemoval{}); err == nil {
		t.Error("пустой track_id должен давать ошибку")
	}
}
