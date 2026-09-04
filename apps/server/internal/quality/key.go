// Package quality — правила отсева мусорных треков, оценки качества файла и
// выбора лучшей версии. Перенос «мозга» из старого проекта
// (apps/api/src/quality/*, charts/normalize-key.ts). Чистые функции, без БД.
//
// Пока в каталоге пусто (чистый старт) — этот пакет подключится, когда сервер
// научится искать и качать музыку. Здесь он с тестами лежит наготове.
package quality

import (
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// NormalizeKeyPart — канон нормализации части ключа сопоставления:
// нижний регистр, убрать диакритику, всё кроме букв/цифр → пробел, схлопнуть.
// «Beyoncé» и «Beyonce», «Sigur Rós» и «Sigur Ros» дают один ключ.
func NormalizeKeyPart(s string) string {
	s = strings.ToLower(s)
	// NFKD раскладывает é → e + combining acute; дальше выкидываем combining.
	decomposed := norm.NFKD.String(s)
	var b strings.Builder
	b.Grow(len(decomposed))
	lastSpace := false
	for _, r := range decomposed {
		if unicode.Is(unicode.Mn, r) {
			continue // combining mark — диакритика
		}
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			b.WriteRune(r)
			lastSpace = false
			continue
		}
		if !lastSpace {
			b.WriteByte(' ')
			lastSpace = true
		}
	}
	return strings.TrimSpace(b.String())
}

// NormalizedKey — ключ «артист__название» для дедупа track_files.
func NormalizedKey(artist, title string) string {
	return NormalizeKeyPart(artist) + "__" + NormalizeKeyPart(title)
}
