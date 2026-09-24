// Package quality — правила отсева мусорных треков, оценки качества файла и
// выбора лучшей версии. Перенос «мозга» из старого проекта
// (apps/api/src/quality/*, charts/normalize-key.ts). Чистые функции, без БД.
//
// Пока в каталоге пусто (чистый старт) — этот пакет подключится, когда сервер
// научится искать и качать музыку. Здесь он с тестами лежит наготове.
package quality

import (
	"regexp"
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

// dropFromTitle — хвосты в названии, которые не делают запись другой песней:
// та же запись, просто с пометкой релиза или лишним повтором соавтора,
// уже упомянутого в артисте. Осторожно: не трогаем «(Live)»/«(Remix)»/
// «(Acoustic)» и т.п. — это правда другая запись звука.
var dropFromTitle = regexp.MustCompile(`(?i)\s*[\(\[](?:feat|ft|featuring)\.?\s+[^)\]]*[\)\]]|\s*[\(\[](?:album version|radio edit|single version|original mix|clean version|explicit version)[\)\]]`)

// FuzzyKey — ключ для «это, похоже, уже есть» при добавлении в каталог
// (Alex TG 24.09.2026: «научи программу, чтобы сама определяла дубли»).
// Шире NormalizedKey: срезает «(feat. …)»/«(Album Version)»/«(Radio Edit)»
// и т.п. из названия, и не различает записи, где слова разошлись/слиплись
// пробелом («One Republic» / «OneRepublic», «Dj Shark» / «DjShark»,
// «In Voice» / «InVoice» внутри названия). НЕ заменяет NormalizedKey —
// используется только для проверки «уже есть» при скане/импорте, чтобы не
// расширять поведение чёрного списка/статистики похожести, которые держат
// NormalizedKey как есть.
func FuzzyKey(artist, title string) string {
	t := dropFromTitle.ReplaceAllString(title, "")
	a := strings.ReplaceAll(NormalizeKeyPart(artist), " ", "")
	b := strings.ReplaceAll(NormalizeKeyPart(t), " ", "")
	return a + "__" + b
}
