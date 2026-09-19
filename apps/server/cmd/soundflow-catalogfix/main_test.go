package main

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/quality"
)

// fixture — временная база со схемой программы + настоящие пустые файлы на диске
// (правило «папка-сборник» читает список файлов папки).
type fixture struct {
	t    *testing.T
	root string
	path string
	db   *sql.DB
	n    int
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "soundflow.db")
	ldb, err := localdb.Open(path) // накатывает схему
	if err != nil {
		t.Fatal(err)
	}
	ldb.Close()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { db.Close() })
	return &fixture{t: t, root: root, path: path, db: db}
}

func (f *fixture) file(rel string) string {
	f.t.Helper()
	p := filepath.Join(f.root, "music", filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		f.t.Fatal(err)
	}
	return p
}

func (f *fixture) exec(q string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(q, args...); err != nil {
		f.t.Fatalf("%s: %v", q, err)
	}
}

// track — запись каталога с файлом. key пустой — здоровый ключ по артисту/названию.
func (f *fixture) track(id, artist, title, album, key, created, path string) {
	f.t.Helper()
	if key == "" {
		key = quality.NormalizedKey(artist, title)
	}
	f.exec(`INSERT INTO tracks (id,artist,title,album,normalized_key,created_at,search_text) VALUES (?,?,?,?,?,?,?)`,
		id, artist, title, album, key, created, strings.ToLower(artist+" "+title+" "+album))
	f.exec(`INSERT INTO track_files (id,track_id,normalized_key,file_path,rejected) VALUES (?,?,?,?,0)`,
		"f_"+id, id, key, path)
}

func (f *fixture) onPhone(dev, id string) {
	f.n++
	f.exec(`INSERT INTO sync_events (event_uuid,device_id,kind,track_id,applied_at) VALUES (?,?,?,?,?)`,
		"ev"+string(rune('a'+f.n)), dev, "download", id, "2026-09-15T10:00:00Z")
}

func (f *fixture) count(q string, args ...any) int {
	f.t.Helper()
	var n int
	if err := f.db.QueryRow(q, args...).Scan(&n); err != nil {
		f.t.Fatal(err)
	}
	return n
}

func build(t *testing.T) *fixture {
	f := newFixture(t)
	const dev = "dev1"
	f.exec(`INSERT INTO devices (id,name,last_sync_at,created_at) VALUES (?,?,?,?)`, dev, "phone", "2026-09-19T00:00:00Z", "x")

	// Сборник «Comp Hits» из двух дисков: имена файлов с номерами, альбома в базе нет.
	a1 := f.file("Comp Hits/Album Artist - Album cd1/01. Deja Vu - Unbreak My Heart.mp3")
	a2 := f.file("Comp Hits/Album Artist - Album cd1/02. T-Spoon - Toms Party.mp3")
	a3 := f.file("Comp Hits/Album Artist - Album cd1/03. Koko - They Dont Care.mp3")
	b1 := f.file("Comp Hits/Album Artist - Album cd2/01. Sugar Ray - Abracadabra.mp3")
	b2 := f.file("Comp Hits/Album Artist - Album cd2/02. Falco - Push Push.mp3")
	b3 := f.file("Comp Hits/Album Artist - Album cd2/03. Erasure - Supernature.mp3")

	// 1) пара «чистый исполнитель» / «с номером»: остаётся чистая, у убираемой есть отметка прослушивания
	f.track("t_clean1", "Deja Vu", "Unbreak My Heart", "", "", "2026-09-15T03:36:00Z", a1)
	f.track("t_num1", "01. Deja Vu", "Unbreak My Heart", "", "", "2026-09-15T05:28:00Z", a1)
	f.onPhone(dev, "t_clean1")
	f.onPhone(dev, "t_num1")
	f.exec(`INSERT INTO feedback_event (event_uuid,device_id,track_id,artist,event_type,value) VALUES ('fe1',?,?,?,?,?)`,
		dev, "t_num1", "01. Deja Vu", "skip", -1)
	f.exec(`UPDATE tracks SET feature_vector=x'0102' WHERE id='t_num1'`) // отпечаток только у убираемой — переедет

	// 2) одиночная запись с номером в исполнителе, двойника нет: срезать номер + альбом
	f.track("t_num2", "02. T-Spoon", "Toms Party", "", "", "2026-09-15T05:28:00Z", a2)
	f.onPhone(dev, "t_num2")

	// 3) болванка «Track 3» + настоящее название рядом
	f.track("t_track3", "03. Koko", "Track 3", "", "", "2026-09-15T03:36:00Z", a3)
	f.track("t_real3", "03. Koko", "They Dont Care", "", "", "2026-09-15T05:28:00Z", a3)
	f.onPhone(dev, "t_track3")
	f.onPhone(dev, "t_real3")

	// 4) вторая папка сборника: одиночные записи с номерами
	f.track("t_b1", "01. Sugar Ray", "Abracadabra", "", "", "2026-09-15T05:28:00Z", b1)
	f.track("t_b2", "02. Falco", "Push Push", "", "", "2026-09-15T05:28:00Z", b2)
	f.track("t_b3", "03. Erasure", "Supernature", "", "", "2026-09-15T05:28:00Z", b3)

	// 5) «100 Hits»-двойник: одинаковые артист/название, у старой записи испорчен ключ
	c1 := f.file("Remix Pack/001 Нюша - Больно.mp3")
	f.track("t_bad5", "Нюша", "Больно", "Remix", "iþøa__aieuii", "2026-09-14T10:20:00Z", c1)
	f.track("t_good5", "Нюша", "Больно", "Remix", "", "2026-09-14T11:36:00Z", c1)
	f.onPhone(dev, "t_bad5")
	f.onPhone(dev, "t_good5")

	// 6) подозрительная пара — названия разные: применять нельзя, только пропустить
	d1 := f.file("Odd/song.mp3")
	f.track("t_odd1", "Artist", "First Song", "", "", "2026-09-15T03:00:00Z", d1)
	f.track("t_odd2", "Artist", "Completely Other", "", "", "2026-09-15T04:00:00Z", d1)
	f.onPhone(dev, "t_odd1")
	f.onPhone(dev, "t_odd2")

	// 7) обычная песня — остаться как есть; и настоящий «50 Cent» в папке без номеров
	e1 := f.file("Rap/50 Cent - In da Club.mp3")
	f.track("t_50", "50 Cent", "In da Club", "", "", "2026-09-15T03:00:00Z", e1)
	f.onPhone(dev, "t_50")

	// 8) на телефоне лежит только запись с испорченным ключом: остаётся ОНА (песня не
	// пропадает с телефона и не качается заново), но с данными здоровой записи
	g1 := f.file("Remix Pack/002 Артист - Песня.mp3")
	f.track("t_bad6", "Артист", "Песня", "", "xx__yy", "2026-09-14T10:20:00Z", g1)
	f.track("t_good6", "Артист", "Песня", "", "", "2026-09-14T11:36:00Z", g1)
	f.onPhone(dev, "t_bad6")

	// 9) та же песня уже есть в другом месте отдельным файлом (другая версия): у записи
	// из сборника номер срезаем, а ключ оставляем прежним — он уникален
	h1 := f.file("Comp Hits/Album Artist - Album cd1/04. Mark'Oh - Fade To Grey.mp3")
	f.track("t_conf", "04. Mark'Oh", "Fade To Grey", "", "", "2026-09-15T05:28:00Z", h1)
	h2 := f.file("Other Album/05_Mark'Oh - Fade To Grey.mp3")
	f.track("t_confother", "Mark'Oh", "Fade To Grey", "Other Album", "", "2026-09-15T03:26:00Z", h2)
	f.onPhone(dev, "t_conf")
	f.onPhone(dev, "t_confother")
	return f
}

func TestDryRunChangesNothingAndReports(t *testing.T) {
	f := build(t)
	before := f.count(`SELECT COUNT(*) FROM tracks`)
	var out strings.Builder
	if err := run(f.path, false, "", "", &out); err != nil {
		t.Fatal(err)
	}
	if after := f.count(`SELECT COUNT(*) FROM tracks`); after != before {
		t.Fatalf("сухой прогон изменил базу: %d → %d", before, after)
	}
	if f.count(`SELECT COUNT(*) FROM sync_plans`) != 0 {
		t.Fatal("сухой прогон записал план")
	}
	rep := out.String()
	for _, want := range []string{"СУХОЙ ПРОГОН", "Comp Hits", "t_num1", "ПРОПУЩЕНО"} {
		if !strings.Contains(rep, want) {
			t.Errorf("в отчёте нет %q:\n%s", want, rep)
		}
	}
}

func TestApplyMergesAndFixesCompilations(t *testing.T) {
	f := build(t)
	var out strings.Builder
	if err := run(f.path, true, "", "", &out); err != nil {
		t.Fatalf("apply: %v\n%s", err, out.String())
	}
	rep := out.String()
	if !strings.Contains(rep, "все проверки прошли") {
		t.Errorf("проверка после применения не прошла:\n%s", rep)
	}

	// убраны: с номером, болванка «Track 3», испорченный ключ. Остались 4 + 3 + 2 + подозрительная пара + 50 Cent
	for _, gone := range []string{"t_num1", "t_track3", "t_bad5"} {
		if f.count(`SELECT COUNT(*) FROM tracks WHERE id=?`, gone) != 0 {
			t.Errorf("%s должна быть убрана", gone)
		}
		if f.count(`SELECT COUNT(*) FROM track_files WHERE track_id=?`, gone) != 0 {
			t.Errorf("файловая запись %s осталась", gone)
		}
		if f.count(`SELECT COUNT(*) FROM sync_events WHERE track_id=?`, gone) != 0 {
			t.Errorf("события «на телефоне» %s остались", gone)
		}
	}
	for _, kept := range []string{"t_clean1", "t_real3", "t_good5", "t_odd1", "t_odd2", "t_50"} {
		if f.count(`SELECT COUNT(*) FROM tracks WHERE id=?`, kept) != 1 {
			t.Errorf("%s должна остаться", kept)
		}
	}

	// сам файл общий — на месте
	if _, err := os.Stat(filepath.Join(f.root, "music", "Comp Hits", "Album Artist - Album cd1", "01. Deja Vu - Unbreak My Heart.mp3")); err != nil {
		t.Fatalf("файл сборника пропал: %v", err)
	}

	// у оставшейся записи: альбом = имя папки-сборника (оба диска — один альбом), исполнитель чистый
	for id, wantArtist := range map[string]string{"t_clean1": "Deja Vu", "t_num2": "T-Spoon", "t_real3": "Koko", "t_b1": "Sugar Ray", "t_b2": "Falco", "t_b3": "Erasure"} {
		var artist, album string
		if err := f.db.QueryRow(`SELECT artist, album FROM tracks WHERE id=?`, id).Scan(&artist, &album); err != nil {
			t.Fatal(err)
		}
		if artist != wantArtist || album != "Comp Hits" {
			t.Errorf("%s: получил %q / %q, ждал %q / «Comp Hits»", id, artist, album, wantArtist)
		}
	}
	// ключ пересчитан и в tracks, и в track_files; поиск видит новый альбом
	var key, fkey, search string
	if err := f.db.QueryRow(`SELECT t.normalized_key, f.normalized_key, t.search_text FROM tracks t JOIN track_files f ON f.track_id=t.id WHERE t.id='t_num2'`).Scan(&key, &fkey, &search); err != nil {
		t.Fatal(err)
	}
	if want := quality.NormalizedKey("T-Spoon", "Toms Party"); key != want || fkey != want {
		t.Errorf("ключ t_num2: %q / %q, ждал %q", key, fkey, want)
	}
	if !strings.Contains(search, "comp hits") {
		t.Errorf("search_text без нового альбома: %q", search)
	}
	// настоящее число в имени исполнителя не тронуто
	var a50 string
	_ = f.db.QueryRow(`SELECT artist FROM tracks WHERE id='t_50'`).Scan(&a50)
	if a50 != "50 Cent" {
		t.Errorf("50 Cent испорчен: %q", a50)
	}

	// отметка и отпечаток убранной записи переехали на оставшуюся
	if f.count(`SELECT COUNT(*) FROM feedback_event WHERE track_id='t_clean1' AND artist='Deja Vu'`) != 1 {
		t.Error("отметка пропуска не переехала на оставшуюся запись")
	}
	if f.count(`SELECT COUNT(*) FROM tracks WHERE id='t_clean1' AND feature_vector IS NOT NULL`) != 1 {
		t.Error("отпечаток не переехал на оставшуюся запись")
	}

	// план телефона: убранные записи, что были на телефоне, — на удаление; пропущенная пара не тронута
	var addJSON, remJSON string
	if err := f.db.QueryRow(`SELECT add_ids, remove_ids FROM sync_plans WHERE device_id='dev1'`).Scan(&addJSON, &remJSON); err != nil {
		t.Fatalf("плана нет: %v", err)
	}
	var rem []string
	_ = json.Unmarshal([]byte(remJSON), &rem)
	got := strings.Join(rem, ",")
	for _, id := range []string{"t_num1", "t_track3", "t_bad5"} {
		if !strings.Contains(got, id) {
			t.Errorf("в плане удаления нет %s: %s", id, got)
		}
	}
	if strings.Contains(got, "t_odd") || strings.Contains(got, "t_clean1") {
		t.Errorf("в плане удаления лишнее: %s", got)
	}
	if f.count(`SELECT COUNT(*) FROM server_log WHERE detail LIKE '%слито%'`) != 1 {
		t.Error("нет записи в журнале сервера")
	}

	// на телефоне была только запись с испорченным ключом: остаётся она, ключ и данные — здоровые
	if f.count(`SELECT COUNT(*) FROM tracks WHERE id='t_good6'`) != 0 || f.count(`SELECT COUNT(*) FROM tracks WHERE id='t_bad6'`) != 1 {
		t.Error("для пары 6 должна остаться запись, лежащая на телефоне (t_bad6), а не t_good6")
	}
	var k6, fk6 string
	if err := f.db.QueryRow(`SELECT t.normalized_key, f.normalized_key FROM tracks t JOIN track_files f ON f.track_id=t.id WHERE t.id='t_bad6'`).Scan(&k6, &fk6); err != nil {
		t.Fatal(err)
	}
	if want := quality.NormalizedKey("Артист", "Песня"); k6 != want || fk6 != want {
		t.Errorf("ключ t_bad6 после слияния: %q / %q, ждал %q", k6, fk6, want)
	}
	if strings.Contains(got, "t_bad6") {
		t.Errorf("запись t_bad6 остаётся на телефоне, а в плане удаления есть: %s", got)
	}
	// ключ занят другим файлом той же песни: номер срезан, ключ прежний
	var artistConf, keyConf string
	if err := f.db.QueryRow(`SELECT artist, normalized_key FROM tracks WHERE id='t_conf'`).Scan(&artistConf, &keyConf); err != nil {
		t.Fatal(err)
	}
	if artistConf != "Mark'Oh" || keyConf != quality.NormalizedKey("04. Mark'Oh", "Fade To Grey") {
		t.Errorf("t_conf: %q / ключ %q — ждал срезанный номер и прежний ключ", artistConf, keyConf)
	}
	if f.count(`SELECT COUNT(*) FROM tracks WHERE id='t_confother' AND album='Other Album'`) != 1 {
		t.Error("отдельный файл той же песни не должен меняться")
	}

	// повторный прогон — уже нечего менять
	var out2 strings.Builder
	if err := run(f.path, false, "", "", &out2); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out2.String(), "будет слито 0") || !strings.Contains(out2.String(), "правки оставшихся записей: 0") {
		t.Errorf("после применения остались правки:\n%s", out2.String())
	}
}

func TestPlanKeepsExistingPhonePlan(t *testing.T) {
	f := build(t)
	f.exec(`INSERT INTO sync_plans (device_id,add_ids,remove_ids,created_at) VALUES ('dev1','["t_new","t_num1"]','["t_old"]','x')`)
	if err := run(f.path, true, "", "", &strings.Builder{}); err != nil {
		t.Fatal(err)
	}
	var addJSON, remJSON string
	_ = f.db.QueryRow(`SELECT add_ids, remove_ids FROM sync_plans WHERE device_id='dev1'`).Scan(&addJSON, &remJSON)
	if !strings.Contains(addJSON, "t_new") || strings.Contains(addJSON, "t_num1") {
		t.Errorf("add_ids: %s (t_new остаётся, убранная t_num1 уходит)", addJSON)
	}
	if !strings.Contains(remJSON, "t_old") || !strings.Contains(remJSON, "t_num1") {
		t.Errorf("remove_ids: %s (прежнее остаётся, убранные дописаны)", remJSON)
	}
}
