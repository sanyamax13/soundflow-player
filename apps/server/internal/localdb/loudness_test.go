package localdb

import (
	"path/filepath"
	"testing"
)

func TestLoudnessRoundTrip(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	for _, id := range []string{"a", "b"} {
		if _, err := d.sql.Exec(`INSERT INTO tracks(id, artist, title, normalized_key) VALUES(?, 'X', ?, ?)`, id, id, id); err != nil {
			t.Fatal(err)
		}
	}
	if err := d.SetLoudness("a", -9.5); err != nil {
		t.Fatal(err)
	}
	if err := d.SetLoudness("b", LoudnessUnknown); err != nil {
		t.Fatal(err)
	}
	m, err := d.TrackLoudness()
	if err != nil {
		t.Fatal(err)
	}
	if len(m) != 1 || m["a"] != -9.5 {
		t.Fatalf("got %v", m)
	}
}
