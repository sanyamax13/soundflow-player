package localdb

import (
	"encoding/json"
	"math/rand"
	"testing"
)

// insertReviewTrack — трек с отпечатком и живым файлом (без файла в очередь
// «разбор коллекции» не попадает — нечего слушать).
func insertReviewTrack(t *testing.T, d *DB, id string, vec []float32) {
	t.Helper()
	if _, err := d.sql.Exec(
		`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
		id, "A "+id, id, id, vecToBlob(vec)); err != nil {
		t.Fatal(err)
	}
	if _, err := d.sql.Exec(
		`INSERT INTO track_files (id, track_id, normalized_key, file_path, size_bytes, rejected) VALUES (?,?,?,?,1,0)`,
		"f_"+id, id, id, "p_"+id); err != nil {
		t.Fatal(err)
	}
}

func TestTasteReviewQueueExcludesDecidedAndSortsAscending(t *testing.T) {
	d := open(t)
	const dim = VecDim
	rng := rand.New(rand.NewSource(11))

	// кластер вкуса вокруг оси 0, построенный из лайкнутых треков
	for i := 0; i < 12; i++ {
		id := "liked_" + itoa(i)
		v := make([]float32, dim)
		for j := range v {
			v[j] = float32(rng.NormFloat64() * 0.01)
		}
		v[0] += 1
		insertReviewTrack(t, d, id, v)
		if _, err := d.SaveSync(Device{ID: "d"}, []SyncEvent{
			{UUID: "u_" + id, Kind: "like", TrackID: id, Payload: json.RawMessage(``), ClientTS: 1},
		}); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatalf("recompute: %v", err)
	}

	// near — рядом с осью вкуса (0), far — далеко; оба ЕЩЁ НЕ решены
	near := make([]float32, dim)
	near[0] = 3
	insertReviewTrack(t, d, "near", near)
	far := make([]float32, dim)
	far[500] = 3
	insertReviewTrack(t, d, "far", far)

	// уже решённые — не должны попасть в очередь
	fav := make([]float32, dim)
	fav[0] = 3
	insertReviewTrack(t, d, "already_favorite", fav)
	if _, err := d.sql.Exec(`INSERT INTO legacy_marks (normalized_key, kind) VALUES ('already_favorite','favorite')`); err != nil {
		t.Fatal(err)
	}
	blk := make([]float32, dim)
	blk[500] = 3
	insertReviewTrack(t, d, "already_blocked", blk)
	if _, err := d.sql.Exec(`INSERT INTO legacy_marks (normalized_key, kind) VALUES ('already_blocked','blocked')`); err != nil {
		t.Fatal(err)
	}
	fed := make([]float32, dim)
	fed[500] = 3
	insertReviewTrack(t, d, "already_feedback", fed)
	if _, err := d.SaveSync(Device{ID: "d"}, []SyncEvent{
		{UUID: "u_fed", Kind: "like", TrackID: "already_feedback", Payload: json.RawMessage(``), ClientTS: 1},
	}); err != nil {
		t.Fatal(err)
	}

	list, err := d.TasteReviewQueue(0)
	if err != nil {
		t.Fatalf("queue: %v", err)
	}

	byID := map[string]TasteReviewTrack{}
	for _, r := range list {
		byID[r.ID] = r
		if r.ID == "liked_0" {
			t.Errorf("liked_0 has feedback (like), should not be in the review queue")
		}
	}
	for _, id := range []string{"already_favorite", "already_blocked", "already_feedback"} {
		if _, ok := byID[id]; ok {
			t.Errorf("%s already decided, should not be in the review queue", id)
		}
	}
	rNear, okNear := byID["near"]
	rFar, okFar := byID["far"]
	if !okNear || !okFar {
		t.Fatalf("near/far missing from queue: near=%v far=%v", okNear, okFar)
	}
	if rNear.Score <= rFar.Score {
		t.Errorf("near score %.3f should be higher than far score %.3f (near is close to taste)", rNear.Score, rFar.Score)
	}

	// отсортировано по возрастанию score
	for i := 1; i < len(list); i++ {
		if list[i].Score < list[i-1].Score {
			t.Fatalf("queue not sorted ascending at %d: %.4f then %.4f", i, list[i-1].Score, list[i].Score)
		}
	}
}

func TestTasteReviewQueueEmptyWithoutClusters(t *testing.T) {
	d := open(t)
	insertReviewTrack(t, d, "solo", []float32{1, 0, 0})
	list, err := d.TasteReviewQueue(0)
	if err != nil {
		t.Fatalf("queue: %v", err)
	}
	if len(list) != 0 {
		t.Errorf("no taste clusters yet → want empty queue, got %d", len(list))
	}
}
