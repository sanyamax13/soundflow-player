package localdb

import (
	"testing"
	"time"
)

func sessionTrack(t *testing.T, d *DB, id string, axis int) {
	t.Helper()
	v := make([]float32, VecDim)
	v[axis] = 1
	if _, err := d.sql.Exec(
		`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
		id, "A", id, id, vecToBlob(v)); err != nil {
		t.Fatal(err)
	}
}

func likeEvent(t *testing.T, d *DB, uuid, trackID string, clientTS int64) {
	t.Helper()
	if _, err := d.sql.Exec(
		`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, client_ts, created_at)
		 VALUES (?,?,?,?,?,?,?)`,
		uuid, trackID, "A", "like", 5.0, clientTS, time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
}

func TestSessionVectorsRecentLikesOnly(t *testing.T) {
	d := open(t)
	now := time.Now()
	sessionTrack(t, d, "recent1", 0)
	sessionTrack(t, d, "old1", 1)
	likeEvent(t, d, "e1", "recent1", now.Add(-30*time.Minute).UnixMilli())
	likeEvent(t, d, "e2", "old1", now.Add(-3*time.Hour).UnixMilli()) // старше 2ч — не в сессию

	vecs, err := d.sessionVectors()
	if err != nil {
		t.Fatal(err)
	}
	if len(vecs) != 1 {
		t.Fatalf("expected 1 session vector (only recent1), got %d", len(vecs))
	}
}

func TestSessionVectorsIgnoresFinish(t *testing.T) {
	d := open(t)
	now := time.Now()
	sessionTrack(t, d, "played1", 0)
	if _, err := d.sql.Exec(
		`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, client_ts, created_at)
		 VALUES (?,?,?,?,?,?,?)`,
		"e1", "played1", "A", "finish", 1.5, now.Add(-10*time.Minute).UnixMilli(), time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	vecs, err := d.sessionVectors()
	if err != nil {
		t.Fatal(err)
	}
	if len(vecs) != 0 {
		t.Fatalf("finish events must not feed session (self-reinforcing loop) — got %d vecs", len(vecs))
	}
}

func TestSessionVectorsIgnoresBadClock(t *testing.T) {
	d := open(t)
	now := time.Now()
	sessionTrack(t, d, "future1", 0)
	sessionTrack(t, d, "ancient1", 1)
	likeEvent(t, d, "e1", "future1", now.Add(1*time.Hour).UnixMilli())     // из будущего
	likeEvent(t, d, "e2", "ancient1", now.Add(-48*time.Hour).UnixMilli()) // старше суток

	vecs, err := d.sessionVectors()
	if err != nil {
		t.Fatal(err)
	}
	if len(vecs) != 0 {
		t.Fatalf("clock-skewed events must be ignored, got %d vecs", len(vecs))
	}
}

func TestSessionVectorsNoLikes(t *testing.T) {
	d := open(t)
	vecs, err := d.sessionVectors()
	if err != nil {
		t.Fatal(err)
	}
	if vecs != nil {
		t.Fatalf("expected nil with no likes, got %v", vecs)
	}
}
