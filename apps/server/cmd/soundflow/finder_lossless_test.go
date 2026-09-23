package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"soundflow/server/internal/pathmap"
	"soundflow/server/internal/sidecar"
)

// testFFmpeg — настоящий ffmpeg для проверки разрезки: рядом с программой на рабочем столе или в PATH; нет — тест пропускается.
func testFFmpeg(t *testing.T) string {
	t.Helper()
	for _, p := range []string{os.Getenv("SOUNDFLOW_FFMPEG"), `C:\Users\brain\Desktop\SoundFlow\ffmpeg.exe`} {
		if p != "" {
			if _, err := os.Stat(p); err == nil {
				return p
			}
		}
	}
	if p, err := exec.LookPath("ffmpeg"); err == nil {
		return p
	}
	t.Skip("ffmpeg не найден — разрезку по .cue не проверить")
	return ""
}

// Образ (5 секунд «тона») + .cue на три песни: вырезаются ВСЕ песни в FLAC, образ стирается, возвращается путь к нужной.
func TestSplitCueTargetCutsAllTracksAndRemovesImage(t *testing.T) {
	ff := testFFmpeg(t)
	dir := t.TempDir()
	image := filepath.Join(dir, "Би-2.wav")
	if out, err := exec.Command(ff, "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=6", image).CombinedOutput(); err != nil {
		t.Fatalf("не смог собрать пробный образ: %v: %s", err, out)
	}
	cue := filepath.Join(dir, "Би-2.cue")
	cueText := "PERFORMER \"Би-2\"\nTITLE \"Би-2\"\nFILE \"Би-2.wav\" WAVE\n" +
		"  TRACK 01 AUDIO\n    TITLE \"Раз\"\n    INDEX 01 00:00:00\n" +
		"  TRACK 02 AUDIO\n    TITLE \"Варвара\"\n    INDEX 01 00:02:00\n" +
		"  TRACK 03 AUDIO\n    TITLE \"Три\"\n    INDEX 01 00:04:00\n"
	if err := os.WriteFile(cue, []byte(cueText), 0o644); err != nil {
		t.Fatal(err)
	}
	res := sidecar.FindAudioResult{Found: true, FilePath: image, CueFile: cue, CueTrack: 2, Source: "rutor_album"}

	out, err := splitCueTarget(pathmap.New(), ff, res)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(dir, "02 - Варвара.flac")
	if out.FilePath != want || out.CueFile != "" || out.CueTrack != 0 || out.Source != "rutor_album" {
		t.Fatalf("out=%+v, ждал путь %s", out, want)
	}
	if out.SizeBytes <= 0 {
		t.Errorf("размер песни не заполнен: %+v", out)
	}
	for _, name := range []string{"01 - Раз.flac", "02 - Варвара.flac", "03 - Три.flac"} {
		if fi, err := os.Stat(filepath.Join(dir, name)); err != nil || fi.Size() == 0 {
			t.Errorf("песни %q нет или пустая: %v", name, err)
		}
	}
	if _, err := os.Stat(image); !os.IsNotExist(err) {
		t.Errorf("образ должен быть стёрт после успешной разрезки: %v", err)
	}
}

// Песни с таким номером в разметке нет — образ НЕ стираем (его ещё можно разобрать иначе).
func TestSplitCueTargetKeepsImageWhenTrackMissing(t *testing.T) {
	ff := testFFmpeg(t)
	dir := t.TempDir()
	image := filepath.Join(dir, "a.wav")
	if out, err := exec.Command(ff, "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=4", image).CombinedOutput(); err != nil {
		t.Fatalf("не смог собрать пробный образ: %v: %s", err, out)
	}
	cue := filepath.Join(dir, "a.cue")
	cueText := "FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"Раз\"\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    TITLE \"Два\"\n    INDEX 01 00:02:00\n"
	if err := os.WriteFile(cue, []byte(cueText), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := splitCueTarget(pathmap.New(), ff, sidecar.FindAudioResult{FilePath: image, CueFile: cue, CueTrack: 7})
	if err == nil || !strings.Contains(err.Error(), "нет песни") {
		t.Fatalf("ждал ошибку про отсутствие песни №7, получил %v", err)
	}
	if _, e := os.Stat(image); e != nil {
		t.Errorf("образ не должен пропасть: %v", e)
	}
}

// Образ называется как будущая песня — не затираем его (ffmpeg -y перезаписал бы исходник).
func TestSplitCueTargetNeverOverwritesImage(t *testing.T) {
	ff := testFFmpeg(t)
	dir := t.TempDir()
	image := filepath.Join(dir, "01 - Раз.flac")
	if out, err := exec.Command(ff, "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", image).CombinedOutput(); err != nil {
		t.Fatalf("не смог собрать пробный образ: %v: %s", err, out)
	}
	before, _ := os.Stat(image)
	cue := filepath.Join(dir, "x.cue")
	cueText := "FILE \"01 - Раз.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"Раз\"\n    INDEX 01 00:00:00\n"
	if err := os.WriteFile(cue, []byte(cueText), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := splitCueTarget(pathmap.New(), ff, sidecar.FindAudioResult{FilePath: image, CueFile: cue, CueTrack: 1}); err == nil {
		t.Fatal("ждал отказ: имя песни совпало с образом")
	}
	after, err := os.Stat(image)
	if err != nil || after.Size() != before.Size() {
		t.Errorf("образ изменился или пропал: %v", err)
	}
}
