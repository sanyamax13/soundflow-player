// Package cuesplit разбирает CUE-разметку (обычно из EAC — Exact Audio
// Copy — при рипе диска) и режет один большой аудиофайл «весь альбом
// одним файлом» на отдельные песни без потери качества: границы треков
// в CUE — точные тайм-коды с самого диска, не на глаз.
//
// Alex TG 14.09.2026: скачал 3 альбома группы «Градусы» одним FLAC-файлом
// каждый (обложка не подтягивалась именно поэтому — весь альбом считался
// одной «песней»), рядом лежала .cue-разметка. Ставим на будущее: сканер
// папки при виде большого файла с .cue-разметкой рядом режет автоматически.
package cuesplit

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/charmap"

	"soundflow/server/internal/tagfix"
)

// Track — одна песня из разметки.
type Track struct {
	Num      int
	Title    string
	Artist   string
	StartSec float64 // INDEX 01 — начало трека (не INDEX 00 — это преролл/пауза)
}

// Cue — разобранная разметка одного альбома.
type Cue struct {
	Album        string
	AlbumArtist  string
	AudioFileRef string // как записано в FILE "..." — без учёта расширения (.wav вместо .flac — обычное дело у EAC)
	Tracks       []Track
}

var (
	reFile   = regexp.MustCompile(`(?i)^FILE\s+"([^"]*)"`)
	reTrack  = regexp.MustCompile(`(?i)^TRACK\s+(\d+)\s+AUDIO`)
	reTitle  = regexp.MustCompile(`(?i)^TITLE\s+"([^"]*)"`)
	rePerf   = regexp.MustCompile(`(?i)^PERFORMER\s+"([^"]*)"`)
	reIndex1 = regexp.MustCompile(`(?i)^INDEX\s+01\s+(\d+):(\d+):(\d+)`)
)

// Parse читает .cue-файл. Кодировка не помечена в самом файле почти
// никогда (это текстовый .cue, не ID3) — пробуем UTF-8, при ошибке cp1251
// (тот же вид, что и в тегах — см. internal/tagfix).
func Parse(path string) (*Cue, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	text := string(raw)
	if !utf8.ValidString(text) {
		if fixed, derr := charmap.Windows1251.NewDecoder().String(text); derr == nil {
			text = fixed
		}
	}

	c := &Cue{}
	var cur *Track
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if m := reFile.FindStringSubmatch(line); m != nil {
			c.AudioFileRef = m[1]
			continue
		}
		if m := reTrack.FindStringSubmatch(line); m != nil {
			if cur != nil {
				c.Tracks = append(c.Tracks, *cur)
			}
			num, _ := strconv.Atoi(m[1])
			cur = &Track{Num: num}
			continue
		}
		if m := reTitle.FindStringSubmatch(line); m != nil {
			title := tagfix.Sanitize(m[1])
			if cur == nil {
				c.Album = title
			} else {
				cur.Title = title
			}
			continue
		}
		if m := rePerf.FindStringSubmatch(line); m != nil {
			perf := tagfix.Sanitize(m[1])
			if cur == nil {
				c.AlbumArtist = perf
			} else {
				cur.Artist = perf
			}
			continue
		}
		if m := reIndex1.FindStringSubmatch(line); m != nil && cur != nil {
			mm, _ := strconv.Atoi(m[1])
			ss, _ := strconv.Atoi(m[2])
			ff, _ := strconv.Atoi(m[3])
			cur.StartSec = float64(mm*60+ss) + float64(ff)/75.0
			continue
		}
	}
	if cur != nil {
		c.Tracks = append(c.Tracks, *cur)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(c.Tracks) == 0 {
		return nil, fmt.Errorf("cuesplit: в %s не нашлось ни одного TRACK", path)
	}
	return c, nil
}

// stem — имя файла без расширения, для сравнения без учёта регистра.
func stem(name string) string {
	return strings.ToLower(strings.TrimSuffix(name, filepath.Ext(name)))
}

// FindFor ищет .cue-файл в той же папке, что audioPath, чья ссылка FILE
// указывает (по имени без расширения — EAC часто пишет FILE "....wav" для
// уже готового .flac) на этот же аудиофайл. Возвращает "", false, если не
// нашлось — это НЕ ошибка, просто у файла нет разметки.
func FindFor(audioPath string) (cuePath string, cue *Cue, ok bool) {
	dir := filepath.Dir(audioPath)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", nil, false
	}
	want := stem(filepath.Base(audioPath))
	var fallback string
	var fallbackCue *Cue
	for _, e := range entries {
		if e.IsDir() || !strings.EqualFold(filepath.Ext(e.Name()), ".cue") {
			continue
		}
		p := filepath.Join(dir, e.Name())
		c, err := Parse(p)
		if err != nil || c.AudioFileRef == "" {
			continue
		}
		if stem(c.AudioFileRef) == want {
			// Предпочитаем cue, чья ссылка совпадает и по расширению
			// (обычно тот, что явно помечен «(FLAC)»).
			if strings.EqualFold(filepath.Ext(c.AudioFileRef), filepath.Ext(audioPath)) {
				return p, c, true
			}
			if fallback == "" {
				fallback, fallbackCue = p, c
			}
		}
	}
	if fallback != "" {
		return fallback, fallbackCue, true
	}
	return "", nil, false
}

// SplitResult — один получившийся файл после разрезки, с песней из cue,
// которая в нём теперь лежит (для тегов при добавлении в каталог).
type SplitResult struct {
	Path  string
	Track Track
}

// Split режет audioPath на отдельные файлы по границам cue — рядом, в ту
// же папку, именами «NN - Название.расширение» (расширение то же, что у
// исходника). ffmpegPath — путь к ffmpeg.exe (или просто "ffmpeg", если
// он есть в PATH). coverPath, если не "" — обложка, которая приклеится к
// каждому получившемуся файлу (embedded picture). Раскодировка на
// FLAC/WAV лосслесс: ffmpeg декодирует в PCM и кодирует обратно, что для
// lossless-кодеков не теряет ни бита; `-ss` идёт ПОСЛЕ `-i` — точный
// (не по ключевым кадрам) срез по времени.
func Split(ffmpegPath, audioPath string, cue *Cue, coverPath string) ([]SplitResult, error) {
	ext := filepath.Ext(audioPath)
	dir := filepath.Dir(audioPath)
	var out []SplitResult
	for i, tr := range cue.Tracks {
		artist := tr.Artist
		if artist == "" {
			artist = cue.AlbumArtist
		}
		name := fmt.Sprintf("%02d - %s%s", tr.Num, sanitizeFilename(tr.Title), ext)
		outPath := filepath.Join(dir, name)

		args := []string{"-y", "-i", audioPath, "-ss", fmt.Sprintf("%.3f", tr.StartSec)}
		if i+1 < len(cue.Tracks) {
			dur := cue.Tracks[i+1].StartSec - tr.StartSec
			args = append(args, "-t", fmt.Sprintf("%.3f", dur))
		}
		args = append(args,
			"-metadata", "artist="+artist,
			"-metadata", "title="+tr.Title,
			"-metadata", "album="+cue.Album,
			"-metadata", fmt.Sprintf("track=%d", tr.Num),
			outPath,
		)
		if err := runFFmpeg(ffmpegPath, args); err != nil {
			return out, fmt.Errorf("трек %d (%s): %w", tr.Num, tr.Title, err)
		}
		if coverPath != "" {
			if err := attachCover(ffmpegPath, outPath, coverPath); err != nil {
				return out, fmt.Errorf("обложка для трека %d: %w", tr.Num, err)
			}
		}
		out = append(out, SplitResult{Path: outPath, Track: tr})
	}
	return out, nil
}

func attachCover(ffmpegPath, audioPath, coverPath string) error {
	tmp := strings.TrimSuffix(audioPath, filepath.Ext(audioPath)) + ".cover-tmp" + filepath.Ext(audioPath)
	args := []string{"-y", "-i", audioPath, "-i", coverPath,
		"-map", "0:a", "-map", "1:v",
		"-c", "copy", "-disposition:v", "attached_pic", tmp}
	if err := runFFmpeg(ffmpegPath, args); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, audioPath)
}

func runFFmpeg(ffmpegPath string, args []string) error {
	cmd := exec.Command(ffmpegPath, args...)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg: %w: %s", err, errb.String())
	}
	return nil
}

var reBadFilenameChars = regexp.MustCompile(`[\\/:*?"<>|]`)

func sanitizeFilename(s string) string {
	s = reBadFilenameChars.ReplaceAllString(s, " ")
	s = strings.TrimSpace(s)
	if s == "" {
		return "трек"
	}
	return s
}
