package localdb

import "testing"

func TestSeedLikesOncePerTrack(t *testing.T) {
	d := open(t)
	if _, err := d.sql.Exec(`INSERT INTO tracks (id, artist, title) VALUES ('t1','Кино','Кукушка'), ('t2','Звери','Танцуй')`); err != nil {
		t.Fatal(err)
	}
	names, err := d.TrackNames()
	if err != nil || len(names) != 2 {
		t.Fatalf("TrackNames: %v %v", names, err)
	}
	n, err := d.SeedLikes([]string{"t1", "t2"}, "yandex")
	if err != nil || n != 2 {
		t.Fatalf("первый раз: %d %v", n, err)
	}
	n, _ = d.SeedLikes([]string{"t1", "t2"}, "yandex")
	if n != 0 {
		t.Fatalf("повтор не должен добавлять, добавил %d", n)
	}
	var v float64
	var artist string
	_ = d.sql.QueryRow(`SELECT value, artist FROM feedback_event WHERE track_id='t1'`).Scan(&v, &artist)
	if v != 5 || artist != "Кино" {
		t.Fatalf("лайк: value=%v artist=%q", v, artist)
	}
}
