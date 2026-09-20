package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"soundflow/server/internal/localdb"
)

// addDeadSong — песня в каталоге, чьего файла нет на диске; size — размер, записанный в каталоге.
func addDeadSong(t *testing.T, e *ctxEnv, id, rel string, size int64) string {
	t.Helper()
	local := filepath.Join(e.root, filepath.FromSlash(rel))
	key := "art " + id + "__title " + id
	if err := e.s.db.InsertTrackWithFile(
		localdb.NewTrack{ID: id, Artist: "Art " + id, Title: "Title " + id, NormalizedKey: key},
		localdb.NewTrackFile{ID: "f_" + id, NormalizedKey: key, FilePath: local, SizeBytes: size}); err != nil {
		t.Fatal(err)
	}
	return local
}

func phoneEvent(t *testing.T, e *ctxEnv, kind, id string) {
	t.Helper()
	if _, err := e.s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"},
		[]localdb.SyncEvent{{UUID: kind + "-" + id, Kind: kind, TrackID: id, ClientTS: 1}}); err != nil {
		t.Fatal(err)
	}
}

func favoriteMark(t *testing.T, e *ctxEnv, id string) {
	t.Helper()
	if _, err := e.s.db.SQL().Exec(`INSERT INTO legacy_marks (normalized_key,kind,artist,title,marked_at)
		VALUES (?, 'favorite', '', '', '2026-09-20T00:00:00Z')`, "art "+id+"__title "+id); err != nil {
		t.Fatal(err)
	}
}

func restoreRequest(t *testing.T, e *ctxEnv, scope string) map[string]any {
	t.Helper()
	rec := httptest.NewRecorder()
	e.s.hRestoreRequest(rec, httptest.NewRequest("POST", "/api/restore/request?scope="+scope, nil))
	if rec.Code != 200 {
		t.Fatalf("запрос возврата: %d %s", rec.Code, rec.Body.String())
	}
	var got map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	return got
}

func putRestore(e *ctxEnv, id string, body []byte) *httptest.ResponseRecorder {
	r := chi.NewRouter()
	r.Put("/api/restore/upload/{id}", e.s.hRestoreUpload)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest(http.MethodPut, "/api/restore/upload/"+id, bytes.NewReader(body)))
	return rec
}

func mp3Bytes(n int) []byte {
	return append([]byte("ID3\x03\x00"), bytes.Repeat([]byte{7}, n-5)...)
}

func restoreState(t *testing.T, e *ctxEnv, id string) string {
	t.Helper()
	row, ok, err := e.s.db.RestoreByTrack(id)
	if err != nil || !ok {
		t.Fatalf("строки возврата для %s нет: %v", id, err)
	}
	return row.State
}

func restoreFixture(t *testing.T) *ctxEnv {
	t.Helper()
	e := ctxFixture(t)
	addDeadSong(t, e, "heard", "Сборник/heard.mp3", 1000)
	addDeadSong(t, e, "liked", "Сборник/liked.mp3", 1000)
	addDeadSong(t, e, "cold", "Сборник/cold.mp3", 1000)
	addDeadSong(t, e, "blk", "Сборник/blk.mp3", 1000)
	e.addSong(t, "alive", "Другая/alive.mp3", "xx")
	phoneEvent(t, e, "play", "heard")
	phoneEvent(t, e, "play", "blk")
	phoneEvent(t, e, "play", "alive")
	favoriteMark(t, e, "liked")
	blockSong(t, e, "blk")
	return e
}

// «Слушанные»: берём мёртвые песни, которые слушали или лайкнули; нетронутые, «не качать» и живые — нет.
// «Все»: все мёртвые, кроме «не качать».
func TestRestoreRequestScopes(t *testing.T) {
	e := restoreFixture(t)

	got := restoreRequest(t, e, "heard")
	if got["dead"] != float64(4) || got["candidates"] != float64(2) || got["added"] != float64(2) {
		t.Fatalf("heard: %v", got)
	}
	wanted, _ := e.s.db.RestoreWantedIDs()
	if !wanted["heard"] || !wanted["liked"] || wanted["cold"] || wanted["blk"] || wanted["alive"] {
		t.Fatalf("в очереди: %v", wanted)
	}
	// повторный запрос ничего не добавляет
	if got := restoreRequest(t, e, "heard"); got["added"] != float64(0) {
		t.Fatalf("повтор: %v", got)
	}
	// «все» добавляет ещё нетронутую, но не «не качать»
	got = restoreRequest(t, e, "all")
	wanted, _ = e.s.db.RestoreWantedIDs()
	if !wanted["cold"] || wanted["blk"] || len(wanted) != 3 {
		t.Fatalf("all: %v %v", got, wanted)
	}

	rec := httptest.NewRecorder()
	e.s.hRestoreRequest(rec, httptest.NewRequest("POST", "/api/restore/request?scope=nope", nil))
	if rec.Code != 400 {
		t.Errorf("чужой scope должен отклоняться: %d", rec.Code)
	}
}

// Пока песня ждёт файл, сверка не считает её пропавшей: ни сама сверка, ни кнопка в окне её из каталога не убирают.
func TestRestoreWantedSongsAreNotReconciledAway(t *testing.T) {
	e, r, clock := reconFixture(t)
	addDeadSong(t, e, "heard", "Сборник/heard.mp3", 1000)
	addDeadSong(t, e, "lost", "Сборник/lost.mp3", 1000)
	phoneEvent(t, e, "play", "heard")

	restoreRequest(t, e, "heard")
	if rep := e.s.findMissing(); rep.Songs != 1 || len(rep.Dead) != 1 || rep.Dead[0].TrackID != "lost" {
		t.Fatalf("пропавшей считается только «lost»: %+v", rep)
	}
	r.auto()
	*clock = clock.Add(20 * time.Minute)
	r.auto()
	if !inCatalog(t, e.s, "heard") || inCatalog(t, e.s, "lost") {
		t.Fatal("сверка должна убрать «lost» и не трогать «heard», который ждёт файл")
	}
	rec := httptest.NewRecorder()
	e.s.hMissingClean(rec, httptest.NewRequest("POST", "/api/catalog/missing/clean", nil))
	if !inCatalog(t, e.s, "heard") {
		t.Fatal("кнопка «убрать» не должна трогать песню, ждущую файл")
	}

	// очередь снята — песня снова считается пропавшей
	if n, err := e.s.db.CancelRestore(); err != nil || n != 1 {
		t.Fatalf("снятие очереди: %d %v", n, err)
	}
	if rep := e.s.findMissing(); rep.Songs != 1 || rep.Dead[0].TrackID != "heard" {
		t.Fatalf("после снятия очереди «heard» снова пропавшая: %+v", rep)
	}
}

// Файл с телефона ложится на прежнее место (папка создаётся заново), записанный размер обновляется,
// песня перестаёт быть пропавшей.
func TestRestoreUploadPutsFileBack(t *testing.T) {
	e := restoreFixture(t)
	restoreRequest(t, e, "heard")
	local := filepath.Join(e.root, "Сборник", "heard.mp3")
	if _, err := os.Stat(filepath.Dir(local)); !os.IsNotExist(err) {
		t.Fatal("папки быть не должно (Alex стёр её)")
	}

	body := mp3Bytes(1200)
	rec := putRestore(e, "heard", body)
	if rec.Code != 200 {
		t.Fatalf("отдача: %d %s", rec.Code, rec.Body.String())
	}
	got, err := os.ReadFile(local)
	if err != nil || !bytes.Equal(got, body) {
		t.Fatalf("файл должен лежать на прежнем месте: %v", err)
	}
	if entries, _ := os.ReadDir(filepath.Dir(local)); len(entries) != 1 {
		t.Errorf("рядом не должно остаться временных файлов: %v", entries)
	}
	if st := restoreState(t, e, "heard"); st != localdb.RestoreDone {
		t.Errorf("состояние %q", st)
	}
	var size int64
	if err := e.s.db.SQL().QueryRow(`SELECT size_bytes FROM track_files WHERE id = 'f_heard'`).Scan(&size); err != nil || size != 1200 {
		t.Errorf("размер в каталоге: %d %v", size, err)
	}
	// heard вернулась, liked ещё ждёт файл (пропавшей не считается), cold и blk не в очереди — пропавшие
	if rep := e.s.findMissing(); len(rep.Dead) != 2 {
		t.Errorf("пропавших должно остаться 2: %+v", rep.Dead)
	}
	if !logHas(t, e, "вернула с телефона") {
		t.Error("в журнале нет записи о возврате")
	}
	// повторная отдача той же песни — уже не ждёт
	if rec := putRestore(e, "heard", body); rec.Code != http.StatusConflict {
		t.Errorf("повтор: %d", rec.Code)
	}
}

// Всё, что не должно попасть на диск: чужая песня, мусор вместо аудио, обрезок, уже лежащий файл.
func TestRestoreUploadRejects(t *testing.T) {
	e := restoreFixture(t)
	restoreRequest(t, e, "heard")
	heard := filepath.Join(e.root, "Сборник", "heard.mp3")

	if rec := putRestore(e, "cold", mp3Bytes(1000)); rec.Code != http.StatusNotFound {
		t.Errorf("песня не из списка: %d", rec.Code)
	}
	if rec := putRestore(e, "heard", []byte(strings.Repeat("не музыка ", 200))); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("мусор вместо аудио: %d", rec.Code)
	}
	if _, err := os.Stat(heard); !os.IsNotExist(err) {
		t.Error("мусор не должен попасть на место файла")
	}
	if entries, _ := os.ReadDir(filepath.Dir(heard)); len(entries) != 0 {
		t.Errorf("временный файл должен быть убран: %v", entries)
	}
	if st := restoreState(t, e, "heard"); st != localdb.RestoreFailed {
		t.Errorf("после отказа состояние %q", st)
	}

	// обрезок: в каталоге 1000 байт, пришло 100
	if rec := putRestore(e, "liked", mp3Bytes(100)); rec.Code != http.StatusUnprocessableEntity {
		t.Errorf("обрезок: %d", rec.Code)
	}

	// файл уже лежит на месте — не перезаписываем
	e2 := restoreFixture(t)
	restoreRequest(t, e2, "heard")
	liked := filepath.Join(e2.root, "Сборник", "liked.mp3")
	if err := os.MkdirAll(filepath.Dir(liked), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(liked, []byte("моё"), 0o644); err != nil {
		t.Fatal(err)
	}
	if rec := putRestore(e2, "liked", mp3Bytes(1000)); rec.Code != 200 || !strings.Contains(rec.Body.String(), "exists") {
		t.Errorf("уже лежит: %d %s", rec.Code, rec.Body.String())
	}
	if b, _ := os.ReadFile(liked); string(b) != "моё" {
		t.Error("существующий файл перезаписан")
	}
}

// Записи песен уже убрала «уборка» каталога (плашка в окне, 21.09.2026): запрос с копией базы возвращает записи
// слушанных песен (не «остальных»), файл с телефона ложится на прежнее место, песня снова целая, а лайки/метки и id
// прежние — телефон узнаёт песню по тому же id.
func TestRestoreFromBackupBringsRecordsAndFilesBack(t *testing.T) {
	e := ctxFixture(t)
	addDeadSong(t, e, "heard", "Сборник/heard.mp3", 1000)
	addDeadSong(t, e, "cold", "Сборник/cold.mp3", 1000)
	addDeadSong(t, e, "blk", "Сборник/blk.mp3", 1000)
	e.addSong(t, "alive", "Другая/alive.mp3", "xx")
	phoneEvent(t, e, "play", "heard")
	phoneEvent(t, e, "play", "blk")
	blockSong(t, e, "blk")
	backup, err := e.s.backupDB("before-reconcile")
	if err != nil {
		t.Fatal(err)
	}
	// «уборка»: записи пропавших ушли из каталога
	rep := e.s.findMissing()
	var ids []string
	for _, m := range rep.Files {
		ids = append(ids, m.FileID)
	}
	if _, _, _, err := e.s.removeMissing(ids, "по кнопке в окне"); err != nil {
		t.Fatal(err)
	}
	if inCatalog(t, e.s, "heard") || inCatalog(t, e.s, "cold") || !inCatalog(t, e.s, "alive") {
		t.Fatal("после уборки должна остаться только живая песня")
	}

	post := func(q string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		e.s.hRestoreRequest(rec, httptest.NewRequest("POST", "/api/restore/request?"+q, nil))
		return rec
	}
	if rec := post("scope=heard&from=" + url.QueryEscape(filepath.Join(e.dir, "soundflow.db"))); rec.Code != 400 {
		t.Errorf("копия вне папки _backup должна отклоняться: %d", rec.Code)
	}
	rec := post("scope=heard&from=" + url.QueryEscape(backup))
	var got map[string]any
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &got) != nil ||
		got["candidates"] != float64(1) || got["ghosts"] != float64(1) || got["added"] != float64(1) {
		t.Fatalf("запрос: %d %s", rec.Code, rec.Body.String())
	}
	if !inCatalog(t, e.s, "heard") || inCatalog(t, e.s, "cold") || inCatalog(t, e.s, "blk") {
		t.Fatal("вернулась должна быть только слушанная песня")
	}
	if rep := e.s.findMissing(); rep.Songs != 0 {
		t.Errorf("пока песня ждёт файл, она не считается пропавшей: %+v", rep)
	}

	local := filepath.Join(e.root, "Сборник", "heard.mp3")
	if rec := putRestore(e, "heard", mp3Bytes(1000)); rec.Code != 200 {
		t.Fatalf("отдача: %d %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(local); err != nil {
		t.Fatalf("файл должен лежать на прежнем месте: %v", err)
	}
	var artist string
	if err := e.s.db.SQL().QueryRow(`SELECT artist FROM tracks WHERE id = 'heard'`).Scan(&artist); err != nil || artist != "Art heard" {
		t.Errorf("запись песни должна быть прежней: %q %v", artist, err)
	}
	// второй запрос ничего не находит: песня уже в каталоге
	rec = post("scope=heard&from=" + url.QueryEscape(backup))
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &got) != nil || got["candidates"] != float64(0) {
		t.Errorf("повтор: %d %s", rec.Code, rec.Body.String())
	}
	// «все» приносит и непрослушанную, но не «не качать»
	rec = post("scope=all&from=" + url.QueryEscape(backup))
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &got) != nil || got["candidates"] != float64(1) || !inCatalog(t, e.s, "cold") || inCatalog(t, e.s, "blk") {
		t.Errorf("all: %d %s", rec.Code, rec.Body.String())
	}
}

// Телефон сообщает, чего у него нет: очередь по ним закрывается, они снова считаются пропавшими.
func TestRestorePhoneMissing(t *testing.T) {
	e := restoreFixture(t)
	restoreRequest(t, e, "heard")

	rec := httptest.NewRecorder()
	e.s.hRestoreMissing(rec, httptest.NewRequest("POST", "/api/restore/missing", strings.NewReader(`{"ids":["liked","nope"]}`)))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"marked":1`) {
		t.Fatalf("missing: %d %s", rec.Code, rec.Body.String())
	}
	if st := restoreState(t, e, "liked"); st != localdb.RestorePhoneMissing {
		t.Errorf("состояние %q", st)
	}
	rec = httptest.NewRecorder()
	e.s.hRestoreStatus(rec, httptest.NewRequest("GET", "/api/restore/status", nil))
	var st map[string]float64
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil || st["wanted"] != 1 || st["phone_missing"] != 1 || st["done"] != 0 {
		t.Fatalf("статус: %s", rec.Body.String())
	}
	rec = httptest.NewRecorder()
	e.s.hRestoreWanted(rec, httptest.NewRequest("GET", "/api/restore/wanted", nil))
	var list []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil || len(list) != 1 || list[0]["id"] != "heard" || list[0]["title"] != "Title heard" {
		t.Fatalf("список: %s", rec.Body.String())
	}
}

func TestLooksLikeAudio(t *testing.T) {
	cases := []struct {
		ext  string
		head []byte
		ok   bool
	}{
		{".mp3", []byte("ID3\x03"), true},
		{".mp3", []byte{0xFF, 0xFB, 0x90}, true},
		{".mp3", []byte("<html>"), false},
		{".flac", []byte("fLaC"), true},
		{".m4a", []byte("\x00\x00\x00\x20ftypM4A "), true},
		{".ogg", []byte("OggS"), true},
		{".wav", []byte("RIFF...."), true},
		{".wma", []byte{0x30, 0x26, 0xB2, 0x75, 0x8E}, true},
		{".mp3", nil, false},
		{".txt", []byte("ID3"), false},
	}
	for _, c := range cases {
		if got := looksLikeAudio(c.ext, c.head); got != c.ok {
			t.Errorf("looksLikeAudio(%q, %q)=%v", c.ext, c.head, got)
		}
	}
}
