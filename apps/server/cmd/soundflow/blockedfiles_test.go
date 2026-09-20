package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/quality"
)

func blockSong(t *testing.T, e *ctxEnv, id string) {
	t.Helper()
	if _, err := e.s.db.ImportBlocked([]localdb.BlockedMark{{
		NormalizedKey: "art " + id + "__title " + id, Artist: "Art " + id, Title: "Title " + id,
	}}); err != nil {
		t.Fatal(err)
	}
}

// Плашка «не качать, а файл лежит»: считаются только песни с меткой и с настоящим файлом на диске;
// песня без метки и песня, чей файл уже пропал, в счёт не идут.
func TestBlockedFilesReportCountsOnlyBlockedWithRealFile(t *testing.T) {
	e := ctxFixture(t)
	e.addSong(t, "t1", "Сборник А/01.mp3", "aaa")
	e.addSong(t, "t2", "Сборник А/02.mp3", "bb")
	e.addSong(t, "t3", "Сборник Б/03.mp3", "c")
	e.addSong(t, "t4", "Сборник А/04.mp3", "") // файла на диске нет
	e.addSong(t, "t5", "Свои/05.mp3", "ddd")   // без метки
	for _, id := range []string{"t1", "t2", "t3", "t4"} {
		blockSong(t, e, id)
	}

	rec := httptest.NewRecorder()
	e.s.hBlockedFiles(rec, httptest.NewRequest("GET", "/api/catalog/blocked-files", nil))
	var got struct {
		Songs   int           `json:"songs"`
		Bytes   int64         `json:"bytes"`
		Folders []folderCount `json:"folders"`
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &got) != nil {
		t.Fatalf("ответ: %d %s", rec.Code, rec.Body.String())
	}
	sum := 0
	for _, f := range got.Folders {
		sum += f.Songs
	}
	// папки в сводке — «диск\папка\подпапка» настоящего пути; во временной папке теста они сливаются в одну
	if got.Songs != 3 || got.Bytes != 6 || sum != 3 {
		t.Errorf("ждали 3 песни, 6 байт, в папках всего 3: %+v", got)
	}
}

// Кнопка «Стереть»: файлы песен из «не качать» стираются насовсем, песни уходят из каталога, метка остаётся,
// чужое не тронуто, опустевшая папка исчезает.
func TestBlockedFilesEraseKeepsMarkAndOthers(t *testing.T) {
	e := ctxFixture(t)
	f1 := e.addSong(t, "t1", "Сборник/01.mp3", "aaa")
	f2 := e.addSong(t, "t2", "Сборник/02.mp3", "bb")
	own := e.addSong(t, "t3", "Свои/03.mp3", "ccc")
	blockSong(t, e, "t1")
	blockSong(t, e, "t2")

	rec := httptest.NewRecorder()
	e.s.hBlockedFilesErase(rec, httptest.NewRequest("POST", "/api/catalog/blocked-files/erase", nil))
	var res deleteResult
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &res) != nil {
		t.Fatalf("ответ: %d %s", rec.Code, rec.Body.String())
	}
	if res.Deleted != 2 || res.FilesErased != 2 || res.Failed != 0 {
		t.Errorf("результат: %+v", res)
	}
	for _, f := range []string{f1, f2} {
		if _, err := os.Stat(f); !os.IsNotExist(err) {
			t.Errorf("файл должен быть стёрт: %s (%v)", f, err)
		}
	}
	if _, err := os.Stat(filepath.Dir(f1)); !os.IsNotExist(err) {
		t.Errorf("опустевшая папка сборника должна исчезнуть (%v)", err)
	}
	if _, err := os.Stat(own); err != nil {
		t.Errorf("своя песня обязана уцелеть: %v", err)
	}
	if inCatalog(t, e.s, "t1") || inCatalog(t, e.s, "t2") || !inCatalog(t, e.s, "t3") {
		t.Errorf("из каталога должны уйти t1 и t2, t3 остаться")
	}
	if b, _ := e.s.db.IsBlocked("art t1__title t1"); !b {
		t.Errorf("метка «не качать» обязана остаться")
	}
	// повторное нажатие ничего не находит
	rec = httptest.NewRecorder()
	e.s.hBlockedFilesErase(rec, httptest.NewRequest("POST", "/api/catalog/blocked-files/erase", nil))
	var again deleteResult
	_ = json.Unmarshal(rec.Body.Bytes(), &again)
	if rec.Code != 200 || again.Deleted != 0 {
		t.Errorf("второй раз стирать нечего: %d %+v", rec.Code, again)
	}
}

// Копия той же песни в другой папке при массовом стирании «не качать» не трогается (в списке окна её не видно).
func TestBlockedFilesEraseLeavesCopiesElsewhere(t *testing.T) {
	e := ctxFixture(t)
	if err := e.s.db.SetSetting(settingWatchDir, e.root); err != nil {
		t.Fatal(err)
	}
	main := e.addNamedSong(t, "t1", "Артист", "Песня", "Сборник", ".mp3")
	cp := e.addCopyFile(t, "Артист", "Песня", "Мой альбом", ".mp3", "copy")
	if _, err := e.s.db.ImportBlocked([]localdb.BlockedMark{{
		NormalizedKey: quality.NormalizedKey("Артист", "Песня"), Artist: "Артист", Title: "Песня",
	}}); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	e.s.hBlockedFilesErase(rec, httptest.NewRequest("POST", "/api/catalog/blocked-files/erase", nil))
	if rec.Code != 200 {
		t.Fatalf("ответ: %d %s", rec.Code, rec.Body.String())
	}
	if exists(main) {
		t.Errorf("основной файл песни должен быть стёрт")
	}
	if !exists(cp) {
		t.Errorf("копия в другой папке обязана остаться: %s", cp)
	}
}
