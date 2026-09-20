// Package coverart — обложка, зашитая в сам аудиофайл (обычно кладут туда
// при рипе альбома). Общее место для HTTP-ручки (internal/api) и догона
// внешних обложек (internal/db + acquire.Finder) — обе должны одинаково
// понимать, есть ли у файла своя картинка, прежде чем идти в сеть.
package coverart

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/dhowden/tag"
)

// Embedded — картинка из тегов файла. ok=false — файл не открылся, теги не
// прочитались, или обложки в них нет; за причиной не гонимся, вызывающему
// достаточно знать факт.
func Embedded(localPath string) (data []byte, mimeType string, ok bool) {
	f, err := os.Open(localPath)
	if err != nil {
		return nil, "", false
	}
	defer f.Close()
	m, err := tag.ReadFrom(f)
	if err != nil {
		return nil, "", false
	}
	pic := m.Picture()
	if pic == nil || len(pic.Data) == 0 {
		return nil, "", false
	}
	ct := pic.MIMEType
	if ct == "" {
		ct = "image/jpeg"
	}
	return pic.Data, ct, true
}

// Имена картинок-обложек, которые кладут рядом с треками (Windows Media Player,
// программы для рипа, iTunes): cover.jpg, folder.jpg, front.png, AlbumArt_{…}_Large.jpg.
// Точное имя из первого списка сильнее, чем просто начало имени.
var (
	folderExactNames = map[string]bool{
		"cover": true, "folder": true, "front": true, "albumart": true, "album": true,
		"artwork": true, "thumb": true, "albumartsmall": true, "albumartlarge": true,
	}
	folderNamePrefixes = []string{"cover", "folder", "front", "albumart"}
	folderImageExts    = map[string]bool{".jpg": true, ".jpeg": true, ".png": true, ".webp": true, ".bmp": true}
)

// FolderImage — картинка-обложка, лежащая в той же папке, что и файл трека
// (audioPath). Alex TG 20146 (20.09.2026): у 421 песни обложки нет в самом
// файле, но есть в папке альбома — раньше телефон о ней не знал. ok=false —
// папки нет или подходящей картинки в ней нет.
func FolderImage(audioPath string) (path string, ok bool) {
	dir := filepath.Dir(audioPath)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	prefixHit := ""
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(e.Name()))
		if !folderImageExts[ext] {
			continue
		}
		base := strings.ToLower(strings.TrimSuffix(e.Name(), filepath.Ext(e.Name())))
		if folderExactNames[base] {
			return filepath.Join(dir, e.Name()), true
		}
		if prefixHit == "" {
			for _, p := range folderNamePrefixes {
				if strings.HasPrefix(base, p) {
					prefixHit = filepath.Join(dir, e.Name())
					break
				}
			}
		}
	}
	return prefixHit, prefixHit != ""
}

// Found — обложка, найденная поиском в интернете и лежащая в папке [dir] под
// именем <id трека>.jpg (или .jpeg/.png/.webp). dir пуст — «найденных» нет.
// id приходит из адреса запроса — filepath.Base режет любые «../».
func Found(dir, trackID string) (path string, ok bool) {
	if dir == "" || trackID == "" {
		return "", false
	}
	id := filepath.Base(trackID)
	for _, ext := range []string{".jpg", ".jpeg", ".png", ".webp"} {
		p := filepath.Join(dir, id+ext)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p, true
		}
	}
	return "", false
}
