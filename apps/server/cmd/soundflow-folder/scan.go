package main

import (
	"crypto/sha1"
	"encoding/hex"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dhowden/tag"
)

// Item — одна песня из выбранной папки.
type Item struct {
	ID          string
	Path        string
	Artist      string
	Title       string
	Album       string
	Format      string // MP3 / M4A / FLAC / OGG / WAV
	MimeType    string
	Size        int64
	DurationSec int // 0 — неизвестно (заполнится в приложении при прослушивании)
	BitrateKbps int // 0 — неизвестно
	HasCover    bool
}

var audioExt = map[string]bool{
	".mp3": true, ".m4a": true, ".flac": true, ".ogg": true, ".wav": true,
	".aac": true, ".opus": true, ".wma": true,
}

var mimeByExt = map[string]string{
	".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".aac": "audio/mp4",
	".flac": "audio/flac", ".ogg": "audio/ogg", ".opus": "audio/ogg",
	".wav": "audio/wav", ".wma": "audio/x-ms-wma",
}

// Scan рекурсивно обходит папку и читает теги. progress зовётся по мере
// обхода (можно nil).
func Scan(root string, progress func(found int)) ([]Item, error) {
	var items []Item
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // недоступный файл/папку просто пропускаем
		}
		if d.IsDir() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		if !audioExt[ext] {
			return nil
		}
		it := readOne(path, ext)
		items = append(items, it)
		if progress != nil {
			progress(len(items))
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(items, func(a, b int) bool {
		if strings.EqualFold(items[a].Artist, items[b].Artist) {
			return strings.ToLower(items[a].Title) < strings.ToLower(items[b].Title)
		}
		return strings.ToLower(items[a].Artist) < strings.ToLower(items[b].Artist)
	})
	return items, nil
}

func readOne(path, ext string) Item {
	it := Item{
		ID:       idFor(path),
		Path:     path,
		Format:   strings.ToUpper(strings.TrimPrefix(ext, ".")),
		MimeType: mimeByExt[ext],
	}
	if fi, err := os.Stat(path); err == nil {
		it.Size = fi.Size()
	}

	f, err := os.Open(path)
	if err == nil {
		defer f.Close()
		if m, err := tag.ReadFrom(f); err == nil {
			it.Artist = clean(m.Artist())
			it.Title = clean(m.Title())
			it.Album = clean(m.Album())
			if p := m.Picture(); p != nil && len(p.Data) > 0 {
				it.HasCover = true
			}
			if ft := string(m.FileType()); ft != "" {
				it.Format = normFormat(ft)
			}
		}
	}

	// Нет тега или он «кракозябра» — берём из имени файла и папки, чтобы в
	// приложении не было мусора (Alex TG 18726).
	if it.Title == "" {
		it.Title = strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	}
	if it.Artist == "" {
		it.Artist = filepath.Base(filepath.Dir(path))
	}
	return it
}

// clean — обрезает пробелы и отбрасывает нечитаемые строки (сплошные знаки
// вопроса / нет букв — как «???? ????????»).
func clean(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	q, letters := 0, 0
	for _, r := range s {
		switch {
		case r == '?':
			q++
		case r > 0x7f || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z'):
			letters++
		}
	}
	if strings.HasPrefix(s, "??") || letters == 0 || q >= letters {
		return ""
	}
	return s
}

func normFormat(ft string) string {
	switch strings.ToUpper(ft) {
	case "MP3":
		return "MP3"
	case "M4A", "ALAC", "AAC", "MP4":
		return "M4A"
	case "FLAC":
		return "FLAC"
	case "OGG":
		return "OGG"
	default:
		return strings.ToUpper(ft)
	}
}

func idFor(path string) string {
	h := sha1.Sum([]byte(strings.ToLower(filepath.ToSlash(path))))
	return "f_" + hex.EncodeToString(h[:8])
}
