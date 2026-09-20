package quality

import (
	"regexp"
	"strings"
)

// Списки слов — синхронизированы со старым проектом (LIVE_WORDS/JUNK_WORDS/…).
// Bare live/concert/концерт ловим только как маркер версии (в скобках, суффиксом
// после разделителя, по фразе или в названии альбома) — «Live Is Life» не режем.
var (
	liveWords   = []string{"live", "concert", "концерт"}
	livePhrases = []string{
		"live at", "live in", "live from", "live session", "live performance",
		"from concert", "концертная версия", "запись с концерта", "с концерта",
		"выступление",
	}

	// Откровенный мусор — не «версия песни», режем всегда по границе слова.
	// interview/podcast/trailer/ad/jingle/ringtone — не песни вообще, а не
	// версия песни; добавлено 04.09.2026 после находки интервью Laura Branigan
	// в перенесённой библиотеке (Alex: "надо понять из всех песен что мусор").
	junkWords = []string{
		"karaoke", "караоке", "nightcore", "slowed", "instrumental", "инструментал", "минусовка",
		"demo", "rehearsal", "репетиция", "bootleg",
		"interview", "интервью", "podcast", "подкаст", "trailer", "трейлер",
		"ringtone", "рингтон", "skit",
		// "jingle"/"джингл" НЕ добавляем — ложно сработало на настоящей песне
		// "Jingle Bell Rock" (04.09.2026, прогон на реальной библиотеке).
	}
	junkPhrases = []string{
		"sped up", "speed up", "fan made", "фан-релиз", "фан релиз",
		"sound effect", "звуковой эффект", "voice memo",
	}

	// Альтернативные, но разрешённые к скачиванию версии (кавер/ремикс/акустика).
	altWords   = []string{"cover", "remix", "acoustic", "version", "кавер", "ремикс", "акустика"}
	altPhrases = []string{"radio edit", "extended mix", "club mix"}

	remasterWords = []string{"remaster", "remastered", "ремастер", "ремастеринг"}
)

func wordRe(words []string) *regexp.Regexp {
	return regexp.MustCompile(`(?i)(?:^|[^\p{L}\p{N}])(` + strings.Join(words, "|") + `)(?:[^\p{L}\p{N}]|$)`)
}

var (
	liveWordAnywhere = wordRe(liveWords)
	liveWordAtStart  = regexp.MustCompile(`(?i)^\s*(` + strings.Join(liveWords, "|") + `)(?:[^\p{L}\p{N}]|$)`)
	junkWordRe       = wordRe(junkWords)
	altWordRe        = wordRe(altWords)
	remasterRe       = regexp.MustCompile(`(?i)(?:^|[^\p{L}\p{N}])(` + strings.Join(remasterWords, "|") + `)(?:[^\p{L}\p{N}]|$)|(?:19|20)\d{2}\s+remaster`)
	explicitRe       = regexp.MustCompile(`(?i)(?:^|[^\p{L}\p{N}])(explicit|explicit version)(?:[^\p{L}\p{N}]|$)|[\[(]e[\])]`)
	cleanRe          = regexp.MustCompile(`(?i)(?:^|[^\p{L}\p{N}])(clean|clean version)(?:[^\p{L}\p{N}]|$)`)
	bracketGroupRe   = regexp.MustCompile(`[\[(]([^)\]]*)[)\]]`)
	separatorSplitRe = regexp.MustCompile(`\s+[-–—|]\s+|:\s+`)
)

func phraseHit(lower string, phrases []string) string {
	for _, p := range phrases {
		if strings.Contains(lower, p) {
			return p
		}
	}
	return ""
}

// liveMarkerHit — маркер live/concert в строке с защитой от ложных срабатываний.
// Возвращает найденное слово/фразу либо "".
func liveMarkerHit(s string) string {
	if s == "" {
		return ""
	}
	lower := strings.ToLower(s)
	if p := phraseHit(lower, livePhrases); p != "" {
		return p
	}
	for _, m := range bracketGroupRe.FindAllStringSubmatch(s, -1) {
		if mm := liveWordAnywhere.FindStringSubmatch(m[1]); mm != nil {
			return strings.ToLower(mm[1])
		}
	}
	segs := separatorSplitRe.Split(s, -1)
	if len(segs) > 1 {
		if mm := liveWordAtStart.FindStringSubmatch(segs[len(segs)-1]); mm != nil {
			return strings.ToLower(mm[1])
		}
	}
	return ""
}

// IsLiveOrConcert — концертная/live-версия (по названию, опц. альбому и URL).
func IsLiveOrConcert(title, album, sourceURL string) bool {
	if liveMarkerHit(title) != "" {
		return true
	}
	if album != "" {
		al := strings.ToLower(album)
		if phraseHit(al, livePhrases) != "" || liveWordAnywhere.MatchString(album) {
			return true
		}
	}
	if sourceURL != "" && liveWordAnywhere.MatchString(sourceURL) {
		return true
	}
	return false
}

// Концертные записи часто выходят без слова «live»: альбом называют «Место Год» («London 1993», «Rock In Rio 1985»,
// «Москва 1993»). Alex TG 20133 (20.09.2026): в «Волне» нашлась «Enjoy The Silence» Depeche Mode из альбома «London 1993»
// (концерт 1993 года, выпущен в 2025), а «Live In Frankfurt» уже ловится словом. Правило узкое: название альбома —
// до четырёх слов и год (1950–2029) в конце, без слов сборника («Best Of 2000», «Bravo Hits 2015», «Summer 2019» — не концерт).
var (
	concertAlbumRe   = regexp.MustCompile(`^\s*(\p{L}[\p{L}\s.'’-]{1,40}?)[\s,–-]+(?:19[5-9]\d|20[0-2]\d)\s*$`)
	compilationWords = wordRe([]string{
		"best", "hits", "hit", "top", "mix", "mixes", "now", "greatest", "collection", "essential", "gold", "party", "dance",
		"remix", "remixes", "summer", "winter", "spring", "autumn", "fall", "chart", "charts", "anthems", "classics", "vol", "volume",
		"лучшее", "лучшие", "хиты", "хит", "сборник", "года", "год", "чарт", "топ", "лето", "зима", "весна", "осень",
	})
)

// LooksLikeConcertAlbum — название альбома похоже на концертную/архивную запись: «Место Год» (см. выше).
// Только для показа предложений («Волна»); на классификацию каталога (ReleaseKind) и скачивание не влияет.
func LooksLikeConcertAlbum(album string) bool {
	m := concertAlbumRe.FindStringSubmatch(album)
	if m == nil {
		return false
	}
	place := m[1]
	if len(strings.Fields(place)) > 3 {
		return false
	}
	return !compilationWords.MatchString(place)
}

// IsJunkVersion — откровенный мусор (karaoke/nightcore/slowed/…).
func IsJunkVersion(title string) bool {
	if title == "" {
		return false
	}
	return junkWordRe.MatchString(title) || phraseHit(strings.ToLower(title), junkPhrases) != ""
}

// IsAltVersion — альтернативная версия (cover/remix/acoustic/radio edit/…).
func IsAltVersion(title string) bool {
	if title == "" {
		return false
	}
	return altWordRe.MatchString(title) || phraseHit(strings.ToLower(title), altPhrases) != ""
}

// IsExplicit — метка explicit по названию (метаданные Яндекса надёжнее, это фолбэк).
func IsExplicit(title string) bool { return explicitRe.MatchString(title) }

// IsCleanVersion — цензурированная версия.
func IsCleanVersion(title string) bool { return cleanRe.MatchString(title) }

// ReleaseKind — грубая классификация версии релиза.
func ReleaseKind(title, album string) string {
	switch {
	case IsLiveOrConcert(title, album, ""):
		return "live"
	case remasterRe.MatchString(title) || remasterRe.MatchString(album):
		return "remaster"
	case wordRe([]string{"remix", "ремикс"}).MatchString(title):
		return "remix"
	case wordRe([]string{"acoustic", "акустика"}).MatchString(title):
		return "acoustic"
	case wordRe([]string{"instrumental", "инструментал", "минусовка"}).MatchString(title):
		return "instrumental"
	case wordRe([]string{"cover", "кавер"}).MatchString(title):
		return "cover"
	case wordRe([]string{"demo"}).MatchString(title):
		return "demo"
	default:
		return "studio"
	}
}

// Verdict — итог отсева.
type Verdict struct {
	OK     bool
	Reason string
}

// Screen — acquisition-фильтр: пускать ли трек в каталог. Режем live/concert и
// откровенный мусор. Каверы и ремиксы разрешены (вернёт OK).
func Screen(artist, title, sourceURL string) Verdict {
	if w := liveMarkerHit(title); w != "" {
		return Verdict{false, `концертная версия ("` + w + `")`}
	}
	if IsLiveOrConcert(title, "", sourceURL) {
		return Verdict{false, "концертная версия"}
	}
	if m := junkWordRe.FindStringSubmatch(title); m != nil {
		return Verdict{false, `мусорная версия ("` + strings.ToLower(m[1]) + `")`}
	}
	if p := phraseHit(strings.ToLower(title), junkPhrases); p != "" {
		return Verdict{false, `мусорная версия ("` + p + `")`}
	}
	return Verdict{OK: true}
}

// DurationMatch — совпадает ли длительность с эталонной. Ремастер бывает
// на десятки секунд длиннее — для доверенных источников допуск шире.
func DurationMatch(expectedSec, actualSec int, trustedSource, hasBadKeyword bool) Verdict {
	const tol = 30
	const tolRemaster = 60
	if expectedSec <= 0 || actualSec <= 0 {
		return Verdict{OK: true}
	}
	diff := expectedSec - actualSec
	if diff < 0 {
		diff = -diff
	}
	if diff <= tol {
		return Verdict{OK: true}
	}
	if diff <= tolRemaster && trustedSource && !hasBadKeyword {
		return Verdict{OK: true}
	}
	return Verdict{false, "длительность не совпала"}
}
