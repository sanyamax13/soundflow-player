package main

import (
	"path/filepath"
	"testing"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/quality"
)

// Подборка дня лежит в кэше весь день; песня, которая с утра попала в каталог (или помечена «больше не
// качать»), из неё пропадает — список не предлагает скачать то, что уже есть (Alex TG 20222).
func TestWaveCacheDropsSongsAlreadyKnown(t *testing.T) {
	e := ctxFixture(t)
	have := yandexWaveOut{YandexID: "1", Artist: "Аквариум", Title: "Город"}
	blocked := yandexWaveOut{YandexID: "2", Artist: "Чужой", Title: "Не надо"}
	fresh := yandexWaveOut{YandexID: "3", Artist: "Новый", Title: "Трек"}
	cacheWave(t, e, have, blocked, fresh)

	key := quality.NormalizedKey(have.Artist, have.Title)
	if err := e.s.db.InsertTrackWithFile(
		localdb.NewTrack{ID: "t_have", Artist: have.Artist, Title: have.Title, NormalizedKey: key},
		localdb.NewTrackFile{ID: "f_have", NormalizedKey: key, FilePath: filepath.Join(e.root, "gorod.mp3")},
	); err != nil {
		t.Fatal(err)
	}
	if _, err := e.s.db.ImportBlocked([]localdb.BlockedMark{{
		NormalizedKey: quality.NormalizedKey(blocked.Artist, blocked.Title), Artist: blocked.Artist, Title: blocked.Title,
	}}); err != nil {
		t.Fatal(err)
	}

	code, out, body := getWave(e, "")
	if code != 200 || len(out) != 1 || out[0].YandexID != "3" {
		t.Fatalf("ждали только новую песню: код %d, %s", code, body)
	}
}
