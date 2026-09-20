package localdb

import (
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// В выборку «проверить обложку» попадают только песни с файлом, не в чёрном списке, у которых
// метка пустая или «искали давно и не нашли»; внешние ссылки и метки «обложка есть» — нет.
func TestTracksNeedingCoverCheckPicksOnlyUnchecked(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "soundflow.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	add := func(id, marker string) {
		t.Helper()
		key := "art " + id + "__title " + id
		if err := d.InsertTrackWithFile(
			NewTrack{ID: id, Artist: "Art " + id, Title: "Title " + id, NormalizedKey: key},
			NewTrackFile{ID: "f_" + id, NormalizedKey: key, FilePath: `G:\m\` + id + ".mp3"}); err != nil {
			t.Fatal(err)
		}
		if marker != "" {
			if err := d.SetCoverMarker(id, marker); err != nil {
				t.Fatal(err)
			}
		}
	}
	add("new", "")
	add("oldnone", "none")          // метка прошлых догонов без даты
	add("stale", "none@2026-09-01") // искали давно — пробуем снова
	add("fresh", "none@2026-09-19") // искали позавчера — рано
	add("edge", "none@2026-09-13")  // ровно на границе — уже не «раньше», не берём
	add("emb", "embedded")
	add("fold", "folder")
	add("fnd", "found")
	add("url", "https://example.com/c.jpg")
	add("blk", "")
	if _, err := d.ImportBlocked([]BlockedMark{{NormalizedKey: "art blk__title blk"}}); err != nil {
		t.Fatal(err)
	}
	// песня без файла (запись осиротела) не в счёт
	if _, err := d.sql.Exec(`INSERT INTO tracks (id, artist, title, normalized_key) VALUES ('nofile','A','T','a__t')`); err != nil {
		t.Fatal(err)
	}

	got, err := d.TracksNeedingCoverCheck("2026-09-13", 100)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, c := range got {
		ids = append(ids, c.ID)
		if c.FilePath == "" || c.Artist == "" || c.Title == "" {
			t.Errorf("не заполнена запись %+v", c)
		}
	}
	sort.Strings(ids)
	if want := "new,oldnone,stale"; strings.Join(ids, ",") != want {
		t.Errorf("ждали %s, получили %v", want, ids)
	}

	// лимит работает
	if got, _ := d.TracksNeedingCoverCheck("2026-09-13", 1); len(got) != 1 {
		t.Errorf("лимит 1: получили %d", len(got))
	}
}

func TestSetCoverMarkerRoundTrip(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "soundflow.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	if err := d.InsertTrackWithFile(
		NewTrack{ID: "t1", Artist: "A", Title: "T", NormalizedKey: "a__t"},
		NewTrackFile{ID: "f1", NormalizedKey: "a__t", FilePath: `G:\m\a.mp3`}); err != nil {
		t.Fatal(err)
	}
	if err := d.SetCoverMarker("t1", "found"); err != nil {
		t.Fatal(err)
	}
	if got, _, _ := d.TrackCoverURL("t1"); got != "found" {
		t.Errorf("метка не записалась: %q", got)
	}
}
