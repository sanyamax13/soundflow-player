package localdb

import (
	"encoding/json"
	"testing"
)

func TestSuggestDownloads(t *testing.T) {
	d := open(t)
	const dim = VecDim

	// вектор около оси axis с малым шумом (детерминированно от i)
	mk := func(id, artist, title string, axis, i int) {
		v := make([]float32, dim)
		v[axis] = 1
		v[(axis+7)%dim] = float32(i%5) * 0.01
		if _, err := d.sql.Exec(
			`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector)
			 VALUES (?,?,?,?,?)`, id, artist, title, id, vecToBlob(v)); err != nil {
			t.Fatal(err)
		}
		if _, err := d.sql.Exec(
			`INSERT INTO track_files (id, track_id, normalized_key, file_path, size_bytes, rejected)
			 VALUES (?,?,?,?,?,0)`, "f_"+id, id, id, "X:\\"+id+".mp3", 4_000_000); err != nil {
			t.Fatal(err)
		}
	}

	// жанр A вокруг оси 0 — часть лайкнем; жанр B вокруг оси 800 — нейтрально
	for i := 0; i < 10; i++ {
		mk(itoa(i)+"_a", "ArtistA", "songA"+itoa(i), 0, i)
	}
	for i := 0; i < 10; i++ {
		mk(itoa(i)+"_b", "ArtistB", "songB"+itoa(i), 800, i)
	}
	// ещё жанр C вокруг оси 400 — «на пробу»/случайное
	for i := 0; i < 6; i++ {
		mk(itoa(i)+"_c", "ArtistC", "songC"+itoa(i), 400, i)
	}

	dev := Device{ID: "d1"}
	// лайкаем 4 трека жанра A и скачиваем их (они на телефоне — в кандидаты не идут)
	evs := []SyncEvent{}
	for i := 0; i < 4; i++ {
		id := itoa(i) + "_a"
		evs = append(evs,
			SyncEvent{UUID: "like_" + id, Kind: "like", TrackID: id, Payload: json.RawMessage(``), ClientTS: 1},
			SyncEvent{UUID: "dl_" + id, Kind: "download", TrackID: id, Payload: json.RawMessage(``), ClientTS: 2},
		)
	}
	if _, err := d.SaveSync(dev, evs); err != nil {
		t.Fatalf("SaveSync: %v", err)
	}
	if _, _, err := d.RecomputeTasteClusters(); err != nil {
		t.Fatalf("clusters: %v", err)
	}

	got, err := d.SuggestDownloads("d1", 10)
	if err != nil {
		t.Fatalf("SuggestDownloads: %v", err)
	}
	if len(got) == 0 || len(got) > 10 {
		t.Fatalf("got %d suggestions; want 1..10", len(got))
	}

	onPhone := map[string]bool{"0_a": true, "1_a": true, "2_a": true, "3_a": true}
	seen := map[string]bool{}
	var tasteA int
	for _, s := range got {
		if onPhone[s.ID] {
			t.Errorf("suggested a track already on phone: %s", s.ID)
		}
		if seen[s.ID] {
			t.Errorf("duplicate suggestion: %s", s.ID)
		}
		seen[s.ID] = true
		if s.Reason == "по вкусу" && s.Artist == "ArtistA" {
			tasteA++
		}
	}
	// оставшиеся треки жанра A (4..9) — самые близкие к вкусу, должны
	// попасть в подбор «по вкусу»
	if tasteA == 0 {
		t.Errorf("expected some ArtistA tracks suggested as «по вкусу»; got none: %+v", got)
	}
	// первый в списке — самый вкусный: жанр A
	if got[0].Artist != "ArtistA" {
		t.Errorf("top suggestion = %q %q; want ArtistA", got[0].Artist, got[0].Title)
	}
}

func TestSuggestDownloadsEmptyWhenAllOnPhone(t *testing.T) {
	d := open(t)
	v := make([]float32, VecDim)
	v[0] = 1
	if _, err := d.sql.Exec(`INSERT INTO tracks (id,artist,title,normalized_key,feature_vector) VALUES ('x','A','x','x',?)`, vecToBlob(v)); err != nil {
		t.Fatal(err)
	}
	if _, err := d.sql.Exec(`INSERT INTO track_files (id,track_id,normalized_key,file_path,size_bytes,rejected) VALUES ('fx','x','x','p',1,0)`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.SaveSync(Device{ID: "d"}, []SyncEvent{
		{UUID: "u", Kind: "download", TrackID: "x", Payload: json.RawMessage(``), ClientTS: 1},
	}); err != nil {
		t.Fatal(err)
	}
	got, err := d.SuggestDownloads("d", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Errorf("want 0 suggestions (everything on phone); got %d", len(got))
	}
}
