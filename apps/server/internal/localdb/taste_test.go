package localdb

import (
	"encoding/json"
	"testing"
)

func TestDeriveFeedback(t *testing.T) {
	cases := []struct {
		kind    string
		payload string
		wantET  string
		wantVal float64
		wantOK  bool
	}{
		{"like", "", "like", 5, true},
		{"unlike", "", "unlike", 0, true},
		{"skip", `{"position_ms":5000,"duration_ms":200000}`, "skip_early", -0.7, true},
		{"skip", `{"position_ms":120000,"duration_ms":200000}`, "skip_normal", -0.3, true},
		{"skip", "", "skip_normal", -0.3, true},
		{"skip", `{"position_ms":8000}`, "skip_early", -0.7, true},
		{"complete", "", "finish", 1.5, true},
		{"delete", `{"reason":"dont_like"}`, "delete_not_my_taste", -5, true},
		{"delete", `{"reason":"wrong_version"}`, "delete_bad_version", 0, true},
		{"delete", "", "delete_not_my_taste", -5, true},
		{"play", "", "", 0, false},
		{"download", "", "", 0, false},
	}
	for _, c := range cases {
		et, val, ok := deriveFeedback(c.kind, json.RawMessage(c.payload), eventReason(json.RawMessage(c.payload)))
		if et != c.wantET || val != c.wantVal || ok != c.wantOK {
			t.Errorf("deriveFeedback(%q,%q) = %q,%v,%v; want %q,%v,%v",
				c.kind, c.payload, et, val, ok, c.wantET, c.wantVal, c.wantOK)
		}
	}
}

func TestTasteRoundTrip(t *testing.T) {
	d := open(t)

	// два трека двух артистов
	if _, err := d.sql.Exec(`INSERT INTO tracks (id, artist, title, normalized_key) VALUES
		('t1','Boards of Canada','Roygbiv','k1'),
		('t2','Nickelback','Photograph','k2')`); err != nil {
		t.Fatalf("seed tracks: %v", err)
	}

	dev := Device{ID: "dev1", Name: "test"}
	ev := func(uuid, kind, track, payload string) SyncEvent {
		return SyncEvent{UUID: uuid, Kind: kind, TrackID: track, Payload: json.RawMessage(payload), ClientTS: 1}
	}
	if _, err := d.SaveSync(dev, []SyncEvent{
		ev("u1", "like", "t1", ""),
		ev("u2", "complete", "t1", ""),
		ev("u3", "skip", "t2", `{"position_ms":3000,"duration_ms":200000}`),
		ev("u4", "delete", "t2", `{"reason":"dont_like"}`),
		ev("u5", "play", "t1", ""), // не сигнал вкуса
	}); err != nil {
		t.Fatalf("SaveSync: %v", err)
	}

	// повторная отправка тех же uuid не должна задвоить feedback_event
	if _, err := d.SaveSync(dev, []SyncEvent{ev("u1", "like", "t1", "")}); err != nil {
		t.Fatalf("SaveSync repeat: %v", err)
	}

	top, bottom, err := d.TasteArtists(10)
	if err != nil {
		t.Fatalf("TasteArtists: %v", err)
	}
	if len(top) != 1 || top[0].Artist != "Boards of Canada" {
		t.Fatalf("top artists = %+v; want [Boards of Canada]", top)
	}
	if top[0].Score != 6.5 { // like 5 + finish 1.5
		t.Errorf("top score = %v; want 6.5", top[0].Score)
	}
	if len(bottom) != 1 || bottom[0].Artist != "Nickelback" {
		t.Fatalf("bottom artists = %+v; want [Nickelback]", bottom)
	}
	if bottom[0].Score != -5.7 { // skip_early -0.7 + delete_not_my_taste -5
		t.Errorf("bottom score = %v; want -5.7", bottom[0].Score)
	}

	totals, err := d.TasteTotals()
	if err != nil {
		t.Fatalf("TasteTotals: %v", err)
	}
	if totals.Events != 4 {
		t.Errorf("totals.Events = %d; want 4", totals.Events)
	}
	if totals.Likes != 1 || totals.Finishes != 1 || totals.Skips != 1 || totals.Deletes != 1 {
		t.Errorf("totals = %+v", totals)
	}
	if totals.Artists != 2 {
		t.Errorf("totals.Artists = %d; want 2", totals.Artists)
	}

	tt, tb, err := d.TasteTracks(10)
	if err != nil {
		t.Fatalf("TasteTracks: %v", err)
	}
	if len(tt) != 1 || tt[0].ID != "t1" || tt[0].Title != "Roygbiv" {
		t.Fatalf("top tracks = %+v", tt)
	}
	if len(tb) != 1 || tb[0].ID != "t2" {
		t.Fatalf("bottom tracks = %+v", tb)
	}

	// RebuildFeedback идемпотентен: строк столько же
	n, err := d.RebuildFeedback()
	if err != nil {
		t.Fatalf("RebuildFeedback: %v", err)
	}
	if n != 4 {
		t.Errorf("RebuildFeedback rows = %d; want 4", n)
	}
}
