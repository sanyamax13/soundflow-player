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
// порчи), или если после раскодирования кириллицы получилось меньше
// половины букв — вероятно, это настоящее имя с акцентами (Beyoncé,
// Mötley Crüe), а не сломанная кодировка, и превращать в них кириллицу
// было бы неправильным угадыванием.
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
	if len(buf) == 0 {
		return "", false
	}
	fixed, err := charmap.Windows1251.NewDecoder().Bytes(buf)
	if err != nil || !utf8.Valid(fixed) {
		return "", false
	}
	out := string(fixed)
	cyr, total := 0, 0
	for _, r := range out {
		if unicode.IsLetter(r) {
			total++
			if r >= 0x0400 && r <= 0x04FF {
				cyr++
			}
		}
	}
	if total == 0 || cyr*2 < total {
		return "", false
	}
	return strings.TrimSpace(out), true
}
