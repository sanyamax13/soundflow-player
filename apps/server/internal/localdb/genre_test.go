package localdb

import "testing"

func TestGenreRoundTrip(t *testing.T) {
	d := open(t)
	for _, id := range []string{"a", "b", "c"} {
		if _, err := d.sql.Exec(`INSERT INTO tracks (id, artist, title, normalized_key, genre_tags) VALUES (?, 'X', ?, ?, '[]')`, id, id, "k"+id); err != nil {
			t.Fatal(err)
		}
	}
	need, err := d.TracksNeedingGenre(10)
	if err != nil || len(need) != 3 {
		t.Fatalf("нужно 3 песни без жанра, получили %d (%v)", len(need), err)
	}
	if err := d.SetGenre("a", "rusrap"); err != nil {
		t.Fatal(err)
	}
	if err := d.SetGenre("b", ""); err != nil { // Яндекс не знает
		t.Fatal(err)
	}
	need, _ = d.TracksNeedingGenre(10)
	if len(need) != 1 || need[0].ID != "c" {
		t.Fatalf("после записи без жанра должна остаться только c, а осталось %+v", need)
	}
	g, err := d.TrackGenres()
	if err != nil {
		t.Fatal(err)
	}
	if len(g) != 1 || g["a"] != "rusrap" {
		t.Fatalf("жанры: %+v, ждали только a=rusrap («не знает» не отдаётся)", g)
	}
}
