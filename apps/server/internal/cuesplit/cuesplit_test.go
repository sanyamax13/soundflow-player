package cuesplit

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sampleCue = `REM GENRE Pop
REM DATE 2011
PERFORMER "Артист"
TITLE "Альбом"
FILE "Артист - Альбом.wav" WAVE
  TRACK 01 AUDIO
    TITLE "Первая"
    PERFORMER "Артист"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Вторая"
    PERFORMER "Артист"
    INDEX 00 03:25:10
    INDEX 01 03:27:10
  TRACK 03 AUDIO
    TITLE "Третья"
    PERFORMER "Артист"
    INDEX 00 07:06:74
    INDEX 01 07:08:74
`

func TestParse_TracksAndTimes(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "test.cue")
	if err := os.WriteFile(p, []byte(sampleCue), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Parse(p)
	if err != nil {
		t.Fatal(err)
	}
	if c.Album != "Альбом" || c.AlbumArtist != "Артист" {
		t.Errorf("альбом/артист = %q/%q", c.Album, c.AlbumArtist)
	}
	if len(c.Tracks) != 3 {
		t.Fatalf("треков = %d, хотел 3", len(c.Tracks))
	}
	if c.Tracks[0].Title != "Первая" || c.Tracks[0].StartSec != 0 {
		t.Errorf("трек 1 = %+v", c.Tracks[0])
	}
	wantSec := 3*60 + 27 + 10.0/75.0
	if got := c.Tracks[1].StartSec; got != wantSec {
		t.Errorf("трек 2 старт = %v, хотел %v", got, wantSec)
	}
	if c.Tracks[2].Title != "Третья" {
		t.Errorf("трек 3 = %+v", c.Tracks[2])
	}
}

func TestFindFor_PrefersMatchingExtension(t *testing.T) {
	dir := t.TempDir()
	// cue, ссылающийся на .wav (как обычно пишет EAC) — должен найтись как fallback
	os.WriteFile(filepath.Join(dir, "album.cue"), []byte(sampleCue), 0o644)
	// cue, явно ссылающийся на .flac — должен победить, раз расширения совпадают
	flacCue := strings.Replace(sampleCue,
		`FILE "Артист - Альбом.wav" WAVE`, `FILE "Артист - Альбом.flac" WAVE`, 1)
	os.WriteFile(filepath.Join(dir, "album (FLAC).cue"), []byte(flacCue), 0o644)

	audioPath := filepath.Join(dir, "Артист - Альбом.flac")
	os.WriteFile(audioPath, []byte("не настоящий flac, просто для проверки поиска"), 0o644)

	cuePath, cue, ok := FindFor(audioPath)
	if !ok {
		t.Fatal("cue не найден")
	}
	if filepath.Base(cuePath) != "album (FLAC).cue" {
		t.Errorf("выбран %q, хотел вариант с точным .flac", cuePath)
	}
	if len(cue.Tracks) != 3 {
		t.Errorf("треков = %d", len(cue.Tracks))
	}
}

func TestFindFor_NoMatch(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "unrelated.cue"), []byte(sampleCue), 0o644)
	audioPath := filepath.Join(dir, "Другой Артист - Другой Альбом.flac")
	os.WriteFile(audioPath, []byte("x"), 0o644)
	if _, _, ok := FindFor(audioPath); ok {
		t.Error("не должно было найтись — имя не совпадает")
	}
}

