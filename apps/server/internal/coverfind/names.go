// Package coverfind — поиск обложки для песни в интернете (Яндекс, Deezer, iTunes,
// AudioDB, MusicBrainz) с ПРОВЕРКОЙ: исполнитель и название из ответа источника
// должны совпасть с нашими, иначе можно поставить чужую обложку (первые же
// пробы без проверки цеплялись за однофамильцев и сборники). Порт проверенного
// поиска, которым 20.09.2026 закрыли 3 343 из 3 530 песен без обложки (Alex TG
// 20152); теперь его делает сама программа (TG 20159: «учи программу всему»).
package coverfind

import (
	"regexp"
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// Fold — имя без регистра, «ё» = «е», без надстрочных знаков и всего, кроме букв
// и цифр: «Ёлка», «елка», «ЕЛКА!» — одно и то же.
func Fold(s string) string {
	s = strings.ToLower(strings.ReplaceAll(s, "ё", "е"))
	var b strings.Builder
	for _, r := range norm.NFKD.String(s) {
		if unicode.Is(unicode.Mn, r) {
			continue
		}
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(unicode.ToLower(r))
		}
	}
	return b.String()
}

var (
	// «feat.», «ft.», «vs», «x», «при участии» между именами — тоже разделители.
	wordSep   = regexp.MustCompile(`(?i)(?:^|\s)(?:feat\.?|ft\.?|featuring|prod\.?|vs\.?|при участии|x)(?:\s|$)`)
	nameSep   = regexp.MustCompile(`[,;/\\&]`)
	brackets  = regexp.MustCompile(`[\(\[\{][^\)\]\}]*[\)\]\}]`)
	junkTitle = regexp.MustCompile(`(?i)\b(?:radio edit|radio mix|radio version|extended(?: mix| version)?|original mix|album version|remaster(?:ed)?(?: \d{4})?|single version|club mix|video edit|explicit|clean)\b|\b(?:feat|ft)\b\.?.*`)
	dashSplit = regexp.MustCompile(`\s[-–—]\s`)
	leadSplit = regexp.MustCompile(`(?i)\s*(?:,|;|/|\s(?:feat\.?|ft\.?)\s)\s*`)
)

// ArtistsOf — имена исполнителей строки «A feat. B & C» по отдельности, свёрнутые.
func ArtistsOf(raw string) []string {
	raw = wordSep.ReplaceAllString(raw, ",")
	var out []string
	for _, p := range nameSep.Split(raw, -1) {
		if f := Fold(p); f != "" {
			out = append(out, f)
		}
	}
	return out
}

// LeadArtist — главный (первый) исполнитель строки, как её просят у источника.
func LeadArtist(raw string) string {
	parts := leadSplit.Split(raw, 2)
	if len(parts) > 0 && strings.TrimSpace(parts[0]) != "" {
		return strings.TrimSpace(parts[0])
	}
	return raw
}

// TitleCore — название без скобок, «radio edit», «remastered» и хвоста « - Live»,
// свёрнутое.
func TitleCore(s string) string {
	s = brackets.ReplaceAllString(s, " ")
	s = junkTitle.ReplaceAllString(s, " ")
	if loc := dashSplit.FindStringIndex(s); loc != nil {
		s = s[:loc[0]]
	}
	return Fold(s)
}

func nameMatch(w, c string) bool {
	if w == "" || c == "" {
		return false
	}
	if w == c {
		return true
	}
	if len([]rune(w)) >= 5 && len([]rune(c)) >= 5 && (strings.Contains(c, w) || strings.Contains(w, c)) {
		return true
	}
	return len([]rune(w)) >= 6 && Ratio(w, c) >= 0.88
}

// ArtistOK — главный (первый) исполнитель нашей песни находится среди исполнителей
// результата. Совпадения только по «feat.»-гостю мало: так «A Great Big World ft.
// Christina Aguilera» цеплялся за чужую песню Кристины.
func ArtistOK(want string, cand []string) bool {
	wl := ArtistsOf(want)
	w := Fold(want)
	if len(wl) > 0 {
		w = wl[0]
	}
	cands := map[string]bool{}
	var joined strings.Builder
	for _, c := range cand {
		for _, x := range ArtistsOf(c) {
			cands[x] = true
		}
		if f := Fold(c); f != "" {
			cands[f] = true
			joined.WriteString(f)
		}
	}
	for c := range cands {
		if nameMatch(w, c) {
			return true
		}
	}
	return len([]rune(w)) >= 5 && strings.Contains(joined.String(), w)
}

// TitleOK — название результата то же, что и наше (без скобок и «radio edit»).
func TitleOK(want, cand string) bool {
	a, b := TitleCore(want), TitleCore(cand)
	if a == "" || b == "" {
		return false
	}
	if a == b {
		return true
	}
	if len([]rune(a)) >= 6 && len([]rune(b)) >= 6 && (strings.Contains(a, b) || strings.Contains(b, a)) {
		return true
	}
	return Ratio(a, b) >= 0.8
}

// Ratio — схожесть строк 0..1 «как difflib.SequenceMatcher.ratio()» (удвоенное
// число совпавших символов на суммарную длину): рекурсивно берём самый длинный
// общий кусок и то же слева и справа от него.
func Ratio(a, b string) float64 {
	ra, rb := []rune(a), []rune(b)
	if len(ra)+len(rb) == 0 {
		return 1
	}
	return 2 * float64(matches(ra, rb)) / float64(len(ra)+len(rb))
}

func matches(a, b []rune) int {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	// самый длинный общий кусок (при равенстве — самый ранний в a, потом в b)
	bestLen, bestA, bestB := 0, 0, 0
	prev := make([]int, len(b)+1)
	for i := 1; i <= len(a); i++ {
		cur := make([]int, len(b)+1)
		for j := 1; j <= len(b); j++ {
			if a[i-1] == b[j-1] {
				cur[j] = prev[j-1] + 1
				if cur[j] > bestLen {
					bestLen, bestA, bestB = cur[j], i-cur[j], j-cur[j]
				}
			}
		}
		prev = cur
	}
	if bestLen == 0 {
		return 0
	}
	return bestLen +
		matches(a[:bestA], b[:bestB]) +
		matches(a[bestA+bestLen:], b[bestB+bestLen:])
}

var (
	// «Гр. «Отпетые мошенники»», «Группа Фристайл», «ВИА «Гра» (Н. Грановская, …)», «Д. Билан».
	searchPrefix   = regexp.MustCompile(`(?i)^\s*(?:гр\.|гр\s|группа\s|ансамбль\s|виа\s|вокально-инструментальный ансамбль\s)\s*`)
	searchQuotes   = regexp.MustCompile(`[«»"“”„]`)
	searchInitials = regexp.MustCompile(`(^|\s)[А-ЯЁA-Z]\.\s+(\p{L}{2,})`)
	searchSpaces   = regexp.MustCompile(`\s+`)
)

// SearchArtist — имя исполнителя для запроса к источнику обложек (27.09.2026, Alex: «гр это группа,
// виа тоже лишнее»): без «Гр.», «ВИА», кавычек, перечня участников в скобках и инициалов.
// «Гр. «Отпетые мошенники»» → «Отпетые мошенники», «Д. Билан» → «Билан».
func SearchArtist(raw string) string {
	s := brackets.ReplaceAllString(raw, " ")
	// «ВИА Гра» — «ВИА» часть названия: без него остаётся «Гра», которое ни с чем не сверить.
	// Приставку убираем, только если после неё остаётся имя хотя бы из 4 букв.
	if rest := searchPrefix.ReplaceAllString(s, ""); len([]rune(Fold(rest))) >= 4 {
		s = rest
	}
	s = searchQuotes.ReplaceAllString(s, " ")
	s = searchInitials.ReplaceAllString(s, "$1$2") // «Д. Билан» → «Билан», но «A.R.T.» не трогаем
	s = strings.TrimSpace(searchSpaces.ReplaceAllString(s, " "))
	if s == "" {
		return strings.TrimSpace(raw)
	}
	return s
}

// SearchTitle — название для запроса: без скобок («(Ремикс DJ Сканер)», «(Club Mix)») и хвоста
// « - Remix». У ремикса так находится обложка оригинальной песни — Alex согласился 27.09.2026.
func SearchTitle(raw string) string {
	s := brackets.ReplaceAllString(raw, " ")
	if loc := dashSplit.FindStringIndex(s); loc != nil {
		s = s[:loc[0]]
	}
	s = strings.TrimSpace(searchSpaces.ReplaceAllString(searchQuotes.ReplaceAllString(s, " "), " "))
	if s == "" {
		return strings.TrimSpace(raw)
	}
	return s
}
