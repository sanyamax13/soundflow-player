package localdb

import (
	"encoding/json"
	"testing"
	"time"
)

func radioTrack(t *testing.T, d *DB, id, artist string, axis int, jitter float32) {
	t.Helper()
	v := make([]float32, VecDim)
	v[axis] = 1
	v[(axis+3)%VecDim] = jitter
	if _, err := d.sql.Exec(
		`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
		id, artist, id, id, vecToBlob(v)); err != nil {
		t.Fatal(err)
	}
}

func TestOrderRadioFallbackNoTaste(t *testing.T) {
	d := open(t)
	radioTrack(t, d, "seed", "S", 0, 0)
	radioTrack(t, d, "a", "A", 0, 0.02)
	radioTrack(t, d, "b", "B", 500, 0.0)
	// центров вкуса нет → OrderRadio должен вести себя как OrderBySimilarity
	got, reordered, err := d.OrderRadio("seed", []string{"b", "a"})
	if err != nil {
		t.Fatal(err)
	}
	want, wr, _ := d.OrderBySimilarity("seed", []string{"b", "a"})
	if !reordered || !wr {
		t.Fatalf("reordered flags: radio=%v sim=%v", reordered, wr)
	}
	if len(got) != len(want) || got[0] != want[0] {
		t.Errorf("radio %v != similarity %v", got, want)
	}
	if got[0] != "a" {
		t.Errorf("closest by sound should be first, got %v", got)
	}
}

func TestOrderRadioTasteAware(t *testing.T) {
	d := open(t)
	// seed и «жанр вкуса» — ось 0; далёкий шум — ось 700. 8 fav-треков —
	// минимум для построения слоя (minClusterTracks), см. Task 2 плана.
	radioTrack(t, d, "seed", "Seed", 0, 0)
	for i := 0; i < 8; i++ {
		radioTrack(t, d, "fav"+itoa(i), "Fav"+itoa(i), 0, float32(i)*0.01)
	}
	// три трека одного нейтрального артиста, близкие по звуку: обычный,
	// недавно пропущенный, и нелюбимого артиста рядом — чтобы правило
	// «≤2 одного артиста подряд» не решало за нас, сравнение по оценке.
	radioTrack(t, d, "n_plain", "Neutral", 0, 0.006)
	radioTrack(t, d, "n_skipped", "Neutral", 0, 0.007)
	radioTrack(t, d, "hated", "HatedArtist", 0, 0.005)
	for i := 0; i < 4; i++ {
		radioTrack(t, d, "far"+itoa(i), "FarArtist"+itoa(i), 700, float32(i)*0.01)
	}

	evs := []SyncEvent{}
	for i := 0; i < 8; i++ {
		evs = append(evs, SyncEvent{UUID: "l" + itoa(i), Kind: "like", TrackID: "fav" + itoa(i), Payload: json.RawMessage(``), ClientTS: 1})
	}
	evs = append(evs, SyncEvent{UUID: "dis", Kind: "dislike", TrackID: "hated", Payload: json.RawMessage(``), ClientTS: 1})
	if _, err := d.SaveSync(Device{ID: "d"}, evs); err != nil {
		t.Fatal(err)
	}
	if _, err := d.sql.Exec(
		`INSERT INTO sync_events (event_uuid, device_id, kind, track_id, payload, client_ts, applied_at)
		 VALUES ('sk','d','skip','n_skipped','{}',1,?)`,
		time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}

	cands := []string{"far0", "hated", "n_skipped", "far1", "fav0", "n_plain", "fav1", "far2", "fav2", "fav3", "far3"}
	got, reordered, err := d.OrderRadio("seed", cands)
	if err != nil {
		t.Fatal(err)
	}
	if !reordered {
		t.Fatal("expected reordered")
	}
	if len(got) != len(cands) {
		t.Fatalf("got %d ids, want %d", len(got), len(cands))
	}
	pos := map[string]int{}
	for i, id := range got {
		pos[id] = i
	}
	// звук+вкус: любимый жанр обгоняет «далёкий»
	if pos["fav0"] > pos["far0"] {
		t.Errorf("fav0 (pos %d) should rank above far0 (pos %d)", pos["fav0"], pos["far0"])
	}
	// недавно пропущенный — ниже такого же по звуку непропущенного (тот же артист)
	if pos["n_skipped"] < pos["n_plain"] {
		t.Errorf("n_skipped (pos %d) should rank below n_plain (pos %d)", pos["n_skipped"], pos["n_plain"])
	}
	// нелюбимый артист — ниже нейтрального такого же по звуку
	if pos["hated"] < pos["n_plain"] {
		t.Errorf("hated (pos %d) should rank below n_plain (pos %d)", pos["hated"], pos["n_plain"])
	}
}
