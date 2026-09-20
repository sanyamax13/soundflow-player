package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/quality"
)

// Ревизия 20.09.2026, п. 1а; Alex TG 20177, вариант 2: «удалять песню целиком, со
// всеми копиями». Копия — другой файл с тем же исполнителем и названием в другой
// папке (скан пропускает его как повтор, в каталоге его нет).

// addNamedSong — песня в каталоге, файл называется «Исполнитель - Название.ext»
// (теги в тестовых файлах не читаются, имя разбирается как в скане).
func (e *ctxEnv) addNamedSong(t *testing.T, id, artist, title, dir, ext string) string {
	t.Helper()
	key := quality.NormalizedKey(artist, title)
	local := filepath.Join(e.root, filepath.FromSlash(dir), artist+" - "+title+ext)
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(local, []byte("main-"+id), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := e.s.db.InsertTrackWithFile(
		localdb.NewTrack{ID: id, Artist: artist, Title: title, NormalizedKey: key},
		localdb.NewTrackFile{ID: "f_" + id, NormalizedKey: key, FilePath: local, SizeBytes: 6}); err != nil {
		t.Fatal(err)
	}
	return local
}

// файл-копия на диске (в каталоге его нет)
func (e *ctxEnv) addCopyFile(t *testing.T, artist, title, dir, ext, content string) string {
	t.Helper()
	local := filepath.Join(e.root, filepath.FromSlash(dir), artist+" - "+title+ext)
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(local, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return local
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func TestDeleteForeverTakesAllCopies(t *testing.T) {
	e := ctxFixture(t)
	if err := e.s.db.SetSetting(settingWatchDir, e.root); err != nil {
		t.Fatal(err)
	}
	main := e.addNamedSong(t, "t1", "Kino", "Gruppa Krovi", "Kino", ".mp3")
	cp1 := e.addCopyFile(t, "Kino", "Gruppa Krovi", "Hity 90", ".mp3", "copy-one") // тот же файл в сборнике
	cp2 := e.addCopyFile(t, "Kino", "Gruppa Krovi", "Old/Rip", ".flac", "copy-two")
	other := e.addNamedSong(t, "t2", "Kino", "Zvezda", "Kino", ".mp3")               // другая песня — не трогать
	otherCopy := e.addCopyFile(t, "Kino", "Zvezda", "Hity 90", ".mp3", "other-copy") // её копия — тоже не трогать

	res, err := e.s.deleteForever(context.Background(), []string{"t1"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Deleted != 1 || res.Failed != 0 || res.FilesErased != 1 || res.Copies != 2 || res.CopiesFailed != 0 {
		t.Fatalf("результат: %+v", res)
	}
	for _, p := range []string{main, cp1, cp2} {
		if exists(p) {
			t.Errorf("файл должен уйти с места: %s", p)
		}
	}
	for _, p := range []string{other, otherCopy} {
		if !exists(p) {
			t.Errorf("чужая песня и её копия обязаны уцелеть: %s", p)
		}
	}
	// стёрты все три файла: "main-t1" (7 байт) + "copy-one" (8) + "copy-two" (8)
	if res.Bytes != 23 {
		t.Errorf("освобождено байт: %d, ждали 23", res.Bytes)
	}
	if inCatalog(t, e.s, "t1") || !inCatalog(t, e.s, "t2") {
		t.Errorf("каталог: t1 должна уйти, t2 остаться")
	}
	// опустевшая папка сборника исчезла, а папка с чужой копией осталась
	if exists(filepath.Join(e.root, "Old")) {
		t.Errorf("опустевшая папка Old должна исчезнуть")
	}
	if !exists(filepath.Join(e.root, "Hity 90")) {
		t.Errorf("папка с чужой копией обязана остаться")
	}
}

// Копий нет — всё как раньше, лишних движений нет.
func TestDeleteForeverWithoutCopies(t *testing.T) {
	e := ctxFixture(t)
	if err := e.s.db.SetSetting(settingWatchDir, e.root); err != nil {
		t.Fatal(err)
	}
	e.addNamedSong(t, "t1", "Kino", "Gruppa Krovi", "Kino", ".mp3")
	e.addNamedSong(t, "t2", "Kino", "Zvezda", "Kino", ".mp3")

	res, err := e.s.deleteForever(context.Background(), []string{"t1"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Copies != 0 || res.FilesErased != 1 {
		t.Errorf("результат: %+v", res)
	}
}

// Папка-источник не задана — искать копии негде, удаление работает как прежде.
func TestDeleteForeverNoWatchDirNoCopies(t *testing.T) {
	e := ctxFixture(t)
	e.addNamedSong(t, "t1", "Kino", "Gruppa Krovi", "Kino", ".mp3")
	e.addCopyFile(t, "Kino", "Gruppa Krovi", "Hity 90", ".mp3", "copy-one")

	res, err := e.s.deleteForever(context.Background(), []string{"t1"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Deleted != 1 || res.Copies != 0 {
		t.Errorf("результат: %+v", res)
	}
}

// Окно спрашивает ПЕРЕД подтверждением, сколько копий, и ничего не меняет.
func TestTrackCopiesCountsAndChangesNothing(t *testing.T) {
	e := ctxFixture(t)
	if err := e.s.db.SetSetting(settingWatchDir, e.root); err != nil {
		t.Fatal(err)
	}
	main := e.addNamedSong(t, "t1", "Kino", "Gruppa Krovi", "Kino", ".mp3")
	cp := e.addCopyFile(t, "Kino", "Gruppa Krovi", "Hity 90", ".mp3", "copy-one")
	e.addNamedSong(t, "t2", "Kino", "Zvezda", "Kino", ".mp3") // без копий

	req := httptest.NewRequest(http.MethodPost, "/api/tracks/copies", strings.NewReader(`{"ids":["t1","t2"]}`))
	rec := httptest.NewRecorder()
	e.s.hTrackCopies(rec, req)
	if rec.Code != 200 {
		t.Fatalf("код %d: %s", rec.Code, rec.Body.String())
	}
	var out struct{ Copies, Songs int }
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.Copies != 1 || out.Songs != 1 {
		t.Errorf("ждали 1 копию у 1 песни, получили %+v", out)
	}
	if !exists(main) || !exists(cp) || !inCatalog(t, e.s, "t1") {
		t.Errorf("подсчёт ничего не должен менять")
	}
}

// eraseFile: файла нет — не ошибка; папку не трогает и говорит об этом; настоящий файл стирает и
// называет размер.
func TestEraseFile(t *testing.T) {
	e := ctxFixture(t)
	f := e.addCopyFile(t, "Kino", "Gruppa Krovi", "A", ".mp3", "aaa")

	if size, erased, err := eraseFile(filepath.Join(e.root, "нет-такого.mp3")); size != 0 || erased || err != nil {
		t.Errorf("нет файла: size=%d erased=%v err=%v", size, erased, err)
	}
	if size, erased, err := eraseFile(""); size != 0 || erased || err != nil {
		t.Errorf("пустой путь: size=%d erased=%v err=%v", size, erased, err)
	}
	if _, erased, err := eraseFile(filepath.Dir(f)); erased || err == nil {
		t.Errorf("папку стирать нельзя: erased=%v err=%v", erased, err)
	}
	if !exists(f) {
		t.Fatalf("папка с файлом обязана уцелеть")
	}
	size, erased, err := eraseFile(f)
	if size != 3 || !erased || err != nil {
		t.Errorf("файл: size=%d erased=%v err=%v", size, erased, err)
	}
	if exists(f) {
		t.Errorf("файл должен быть стёрт")
	}
}
