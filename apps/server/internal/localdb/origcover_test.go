package localdb

import "testing"

func TestOriginalCoverCandidates(t *testing.T) {
	d := open(t)
	ins := func(id, artist, path string) {
		if _, err := d.sql.Exec(`INSERT INTO tracks (id, artist, title, normalized_key) VALUES (?, ?, ?, ?)`, id, artist, id, "k"+id); err != nil {
			t.Fatal(err)
		}
		if _, err := d.sql.Exec(`INSERT INTO track_files (id, track_id, normalized_key, file_path) VALUES (?, ?, ?, ?)`, "f"+id, id, "k"+id, path); err != nil {
			t.Fatal(err)
		}
	}
	// сборник: 3 разных исполнителя в одной папке
	ins("c1", "A", "/m/Hits 2020/01.mp3")
	ins("c2", "B", "/m/Hits 2020/02.mp3")
	ins("c3", "C", "/m/Hits 2020/03.mp3")
	// альбом одного исполнителя
	ins("a1", "Band", "/m/Band - Album/01.mp3")
	ins("a2", "Band", "/m/Band - Album/02.mp3")

	got, err := d.TracksNeedingOriginalCover("2000-01-01", 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("из сборника нужны 3 песни, альбом не трогаем; получили %+v", got)
	}
	if err := d.SetOriginalCover("c1", true); err != nil {
		t.Fatal(err)
	}
	if err := d.SetOriginalCover("c2", false); err != nil {
		t.Fatal(err)
	}
	got, _ = d.TracksNeedingOriginalCover("2000-01-01", 100)
	if len(got) != 1 || got[0].ID != "c3" {
		t.Fatalf("осталась бы только c3, а %+v", got)
	}
	revs, _ := d.OriginalCoverRevs()
	if len(revs) != 1 || revs["c1"] == "" {
		t.Fatalf("метки родных обложек: %+v", revs)
	}
}
