// Package tagfix чинит текст тегов, испорченный неверной кодировкой при
// чтении аудиофайлов — русский текст в Windows-1251 без пометки кодировки.
// Общее место для «сканера папки» (cmd/soundflow/jobs.go — торренты,
// «Найти и скачать», ручной скан) и разового переноса старой библиотеки
// (internal/importer) — раньше правка была только во втором месте, из-за
// чего живой скан пропускал ровно такие сборники с торрентов (Alex TG
// 14.09.2026: «100 HITS REMIX», «Поп-хиты зимы» — «Ëþáý», «Ä. Áèëàí»
// вместо «Любэ», «Д. Билан»).
package tagfix

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/encoding/charmap"
)

// Sanitize чинит одно значение тега (артист/название/альбом). Два разных
// вида порчи одного корня (Windows-1251 без пометки кодировки в файле):
//
//  1. Байты cp1251 сохранены как есть — целиком невалидный UTF-8 (старые
//     ID3v1-теги). Перекодируем как cp1251 напрямую.
//  2. Байты cp1251 сперва прочитаны как ISO-8859-1/Latin-1 (кадр ID3v2
//     помечен не той кодировкой) — на выходе ВСЕГДА валидный UTF-8, эту
//     порчу первая проверка вообще не ловит. Нужен отдельный обратный ход:
//     разобрать строку обратно на байты 0x00-0xFF и уже их раскодировать
//     как cp1251.
func Sanitize(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return s
	}
	if !utf8.ValidString(s) {
		if fixed, err := charmap.Windows1251.NewDecoder().String(s); err == nil && utf8.ValidString(fixed) {
			return strings.TrimSpace(fixed)
		}
		return strings.TrimSpace(strings.ToValidUTF8(s, ""))
	}
	if fixed, ok := unscrambleLatin1AsCP1251(s); ok {
		return fixed
	}
	return s
}

// unscrambleLatin1AsCP1251 — см. пункт 2 выше. Отказывается гадать (ok=false),
// если в строке уже есть кириллица (значит, всё в порядке — трогать нечего),
// если в ней встретился символ вне диапазона Latin-1 (это не наш случай
// порчи), или если ни одно «слово» целиком не состоит из non-ASCII букв —
// вероятно, это настоящее имя с одним акцентом (Beyoncé, Mötley Crüe), а
// не сломанная кодировка, и превращать его в кириллицу было бы неправильным
// угадыванием.
//
// Порог раньше считался долей кириллицы во всей строке (кириллица >= 50%
// букв), но у сборников с торрентов названия часто содержат длинную
// англоязычную ремикс-приписку («Семь морей (New Energy mix)») — она
// перевешивала долю и настоящая порча не чинилась. Слово целиком из
// non-ASCII букв — куда надёжнее сигнал порчи: каждая испорченная
// кириллическая буква ВСЕГДА > 0x7F, а у настоящего акцента (é, ö, ü)
// не-ASCII буква только одна внутри иначе ASCII-слова.
func unscrambleLatin1AsCP1251(s string) (string, bool) {
	buf := make([]byte, 0, len(s))
	for _, r := range s {
		if r >= 0x0400 && r <= 0x04FF {
			return "", false
		}
		if r > 0xFF {
			return "", false
		}
		buf = append(buf, byte(r))
	}
	if len(buf) == 0 || !hasFullyNonASCIIWord(s) {
		return "", false
	}
	fixed, err := charmap.Windows1251.NewDecoder().Bytes(buf)
	if err != nil || !utf8.Valid(fixed) {
		return "", false
	}
	out := string(fixed)
	if !strings.ContainsFunc(out, func(r rune) bool { return r >= 0x0400 && r <= 0x04FF }) {
		return "", false
	}
	return strings.TrimSpace(out), true
}

// hasFullyNonASCIIWord — есть ли в строке буквенное «слово» (подряд идущие
// буквы), где КАЖДАЯ буква > 0x7F. Слово короче двух букв не считается —
// это может быть просто инициал («Ä.»).
func hasFullyNonASCIIWord(s string) bool {
	runLen, allNonASCII, found := 0, true, false
	flush := func() {
		if runLen >= 2 && allNonASCII {
			found = true
		}
		runLen, allNonASCII = 0, true
	}
	for _, r := range s {
		if unicode.IsLetter(r) {
			runLen++
			if r <= 0x7F {
				allNonASCII = false
			}
		} else {
			flush()
		}
	}
	flush()
	return found
}
