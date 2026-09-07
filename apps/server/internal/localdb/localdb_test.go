package localdb

import (
	"path/filepath"
	"strings"
	"testing"
)

func open(t *testing.T) *DB {
	t.Helper()
	d, err := Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func addTrack(t *testing.T, d *DB, id, artist string, vec []float32) {
	t.Helper()
	search := strings.ToLower(artist + " " + id + " ") // artist + title(=id) + album('')
	_, err := d.sql.Exec(
		`INSERT INTO tracks (id,artist,title,normalized_key,feature_vector,created_at,search_text)
		 VALUES (?,?,?,?,?,?,?)`,
		id, artist, id, id, vecToBlob(vec), "2026-01-01T00:00:00Z", search)
	if err != nil {
		t.Fatalf("insert %s: %v", id, err)
	}
	if vec != nil {
		_, err = d.sql.Exec(
			`INSERT INTO track_files (id,track_id,normalized_key,file_path,size_bytes)
			 VALUES (?,?,?,?,?)`, "f_"+id, id, id, "X:\\"+id+".mp3", 1000)
		if err != nil {
			t.Fatalf("insert file %s: %v", id, err)
		}
	}
}

func TestVecRoundTrip(t *testing.T) {
	in := []float32{0, 1, -2.5, 3.25, 1e-7}
	got := blobToVec(vecToBlob(in))
	if len(got) != len(in) {
		t.Fatalf("len %d != %d", len(got), len(in))
	}
	for i := range in {
		if got[i] != in[i] {
			t.Fatalf("[%d] %v != %v", i, got[i], in[i])
		}
	}
	if blobToVec(nil) != nil || vecToBlob(nil) != nil {
		t.Fatal("nil должен оставаться nil")
	}
}

func TestParsePgVector(t *testing.T) {
	v := parsePgVector("[1,2.5,-3]")
	if len(v) != 3 || v[0] != 1 || v[1] != 2.5 || v[2] != -3 {
		t.Fatalf("bad parse: %v", v)
	}
	if parsePgVector("") != nil || parsePgVector("[]") != nil {
		t.Fatal("пустой вектор -> nil")
	}
}

func TestOrderBySimilarity_ByCosine(t *testing.T) {
	d := open(t)
	// seed вдоль оси X; кандидаты под разными углами
	addTrack(t, d, "seed", "S", []float32{1, 0, 0})
	addTrack(t, d, "near", "A", []float32{0.99, 0.14, 0}) // ~8°
	addTrack(t, d, "mid", "B", []float32{0.7, 0.7, 0})    // 45°
	addTrack(t, d, "far", "C", []float32{0, 1, 0})        // 90°
	addTrack(t, d, "novec", "D", nil)                     // без отпечатка -> в хвост

	got, reordered, err := d.OrderBySimilarity("seed",
		[]string{"far", "novec", "mid", "near", "seed"})
	if err != nil {
		t.Fatal(err)
	}
	if !reordered {
		t.Fatal("reordered должно быть true")
	}
	want := []string{"near", "mid", "far", "novec"}
	if len(got) != len(want) {
		t.Fatalf("длина %v != %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("порядок %v, ждали %v", got, want)
		}
	}
}

func TestOrderBySimilarity_ArtistSpread(t *testing.T) {
	d := open(t)
	addTrack(t, d, "seed", "S", []float32{1, 0, 0})
	// три самых близких — один артист; четвёртый (другой артист) чуть дальше
	addTrack(t, d, "a1", "SameGuy", []float32{0.999, 0.045, 0})
	addTrack(t, d, "a2", "SameGuy", []float32{0.998, 0.063, 0})
	addTrack(t, d, "a3", "SameGuy", []float32{0.997, 0.077, 0})
	addTrack(t, d, "b1", "OtherGuy", []float32{0.99, 0.141, 0})

	got, _, err := d.OrderBySimilarity("seed", []string{"a1", "a2", "a3", "b1"})
	if err != nil {
		t.Fatal(err)
	}
	// не должно быть трёх SameGuy подряд: b1 обязан влезть на 3-ю позицию
	if got[0] != "a1" || got[1] != "a2" {
		t.Fatalf("начало не по косинусу: %v", got)
	}
	if got[2] != "b1" {
		t.Fatalf("после двух SameGuy ждали OtherGuy, получили %v", got)
	}
	if got[3] != "a3" {
		t.Fatalf("хвост: %v", got)
	}
}

func TestCatalogSearchAndBlocked(t *testing.T) {
	d := open(t)
	addTrack(t, d, "t1", "Nirvana", []float32{1, 0})
	addTrack(t, d, "t2", "Nirvana", []float32{0, 1})
	// t2 помечен blocked в legacy_marks -> не должен попадать в выдачу
	if _, err := d.sql.Exec(
		`INSERT INTO legacy_marks (normalized_key,kind) VALUES (?,?)`, "t2", "blocked"); err != nil {
		t.Fatal(err)
	}
	rows, err := d.CatalogSearch("nirvana", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].ID != "t1" {
		t.Fatalf("ждали только t1, получили %+v", rows)
	}

	p, ok, err := d.TrackFilePath("t1")
	if err != nil || !ok || p == "" {
		t.Fatalf("TrackFilePath t1: %q ok=%v err=%v", p, ok, err)
	}
}
