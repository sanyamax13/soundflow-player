package localdb

import (
	"path/filepath"
	"testing"
)

func reconcileDB(t *testing.T) *DB {
	t.Helper()
	d, err := Open(filepath.Join(t.TempDir(), "soundflow.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func addOne(t *testing.T, d *DB, id string) {
	t.Helper()
	key := "art " + id + "__title " + id
	if err := d.InsertTrackWithFile(
		NewTrack{ID: id, Artist: "Art " + id, Title: "Title " + id, NormalizedKey: key},
		NewTrackFile{ID: "f_" + id, NormalizedKey: key, FilePath: `G:\m\` + id + ".mp3"}); err != nil {
		t.Fatal(err)
	}
}

func count(t *testing.T, d *DB, q string, args ...any) int {
	t.Helper()
	var n int
	if err := d.sql.QueryRow(q, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// Убираем записи о файлах: песня уходит, только когда у неё не осталось ни одного файла; метки, лайки и события
// не трогаются; «хвост» файла без песни убирается; неизвестный id — не ошибка.
func TestRemoveFileRecords(t *testing.T) {
	d := reconcileDB(t)
	addOne(t, d, "a")
	addOne(t, d, "b")
	addOne(t, d, "c")
	// у песни c второй файл (другая копия)
	if _, err := d.sql.Exec(`INSERT INTO track_files (id,track_id,normalized_key,file_path,downloaded_at)
		VALUES ('f_c2','c','c-copy',?, '2026-09-20T00:00:00Z')`, `G:\m\c2.mp3`); err != nil {
		t.Fatal(err)
	}
	// «хвост»: запись файла без песни (в живой базе такие остались от старых правок вне программы, где
	// внешние ключи выключены; здесь выключаем их на одном соединении)
	d.sql.SetMaxOpenConns(1)
	if _, err := d.sql.Exec(`PRAGMA foreign_keys = OFF`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.sql.Exec(`INSERT INTO track_files (id,track_id,normalized_key,file_path,downloaded_at)
		VALUES ('f_orphan','gone','orphan-key',?, '2026-09-20T00:00:00Z')`, `G:\m\orphan.mp3`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.sql.Exec(`PRAGMA foreign_keys = ON`); err != nil {
		t.Fatal(err)
	}
	// то, что убирать нельзя: метка «больше не качать» и лайк
	if _, err := d.sql.Exec(`INSERT INTO legacy_marks (normalized_key,kind,artist,title,marked_at)
		VALUES ('art a__title a','favorite','Art a','Title a','2026-09-20T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.sql.Exec(`INSERT INTO feedback_event (event_uuid,device_id,track_id,artist,event_type,value,reason,client_ts,created_at)
		VALUES ('e1','dev','a','Art a','like',5,'',1,'2026-09-20T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}

	files, songs, err := d.RemoveFileRecords([]string{"f_a", "f_c", "f_orphan", "no-such-id"})
	if err != nil {
		t.Fatal(err)
	}
	if files != 3 || songs != 1 { // f_a, f_c, f_orphan; песня a ушла, c ещё держится вторым файлом
		t.Fatalf("убрано файлов %d (ждали 3), песен %d (ждали 1)", files, songs)
	}
	if count(t, d, `SELECT COUNT(*) FROM tracks WHERE id='a'`) != 0 {
		t.Error("песня a осталась без файла, а должна была уйти")
	}
	if count(t, d, `SELECT COUNT(*) FROM tracks WHERE id IN ('b','c')`) != 2 {
		t.Error("песни b и c должны остаться")
	}
	if count(t, d, `SELECT COUNT(*) FROM track_files WHERE id IN ('f_b','f_c2')`) != 2 {
		t.Error("чужие записи файлов пропали")
	}
	if count(t, d, `SELECT COUNT(*) FROM legacy_marks`) != 1 || count(t, d, `SELECT COUNT(*) FROM feedback_event`) != 1 {
		t.Error("метка или лайк пропали")
	}

	// второй файл песни c тоже убираем — теперь уходит и она
	files, songs, err = d.RemoveFileRecords([]string{"f_c2"})
	if err != nil || files != 1 || songs != 1 {
		t.Fatalf("files=%d songs=%d err=%v", files, songs, err)
	}
	refs, err := d.AllFileRefs()
	if err != nil || len(refs) != 1 || refs[0].ID != "f_b" {
		t.Fatalf("осталось ждали только f_b: %+v err=%v", refs, err)
	}
}

func TestRemoveFileRecordsEmptyIsNoop(t *testing.T) {
	d := reconcileDB(t)
	addOne(t, d, "a")
	if f, s, err := d.RemoveFileRecords(nil); err != nil || f != 0 || s != 0 {
		t.Fatalf("f=%d s=%d err=%v", f, s, err)
	}
	if count(t, d, `SELECT COUNT(*) FROM tracks`) != 1 {
		t.Error("пустой вызов что-то убрал")
	}
}
