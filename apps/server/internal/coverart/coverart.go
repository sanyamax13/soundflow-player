// Package coverart — обложка, зашитая в сам аудиофайл (обычно кладут туда
// при рипе альбома). Общее место для HTTP-ручки (internal/api) и догона
// внешних обложек (internal/db + acquire.Finder) — обе должны одинаково
// понимать, есть ли у файла своя картинка, прежде чем идти в сеть.
package coverart

import (
	"os"

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
