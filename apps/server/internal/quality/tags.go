package quality

import "regexp"

// Правило (Alex, 08.09.2026): в каталог не должны попадать названия/исполнители/
// альбомы с рекламными хвостами качалок — «(Muzjazz.com)», «[mp3xa.cc]»,
// « by www.2baksa.net», «t.me/…». Чистим на каждом добавлении трека
// (acquire, импорт папки, торрент-альбом). Разовый проход по старой базе —
// в docs/PROGRESS «этап 54».

var (
	// домен: одна-или-более «label.» + TLD из белого списка.
	tagDomain = `(?:[a-z0-9][a-z0-9-]*\.)+(?:com|net|org|club|ru|io|fm|cc|me|info|biz|online|pro|top|site|link|xyz|su|tv|band|store|ua|by|kz)`

	// «(что-то site.tld что-то)» / «[…]» / «{…}» — вся скобка целиком.
	tagBracket = regexp.MustCompile(`(?i)\s*[\(\[\{]\s*(?:https?://)?(?:www\.)?` + tagDomain + `[^)\]}]*[)\]}]`)

	// соцсеть/мессенджер с хвостом-путём: «t.me/xxx», «instagram.com/xxx».
	tagSocial = regexp.MustCompile(`(?i)\s*(?:https?://)?(?:www\.)?(?:t\.me|vk\.com|instagram\.com|youtube\.com|youtu\.be)/\S+`)

	// хвост строки: « - site.tld», « by www.site.tld», « | site.tld/path».
	tagTail = regexp.MustCompile(`(?i)\s+(?:by\s+|[-–—|•·:]\s+)?(?:https?://)?(?:www\.)?` + tagDomain + `(?:/\S*)?\s*$`)

	// вся строка — только адрес сайта.
	tagOnly = regexp.MustCompile(`(?i)^\s*(?:https?://)?(?:www\.)?` + tagDomain + `(?:/\S*)?\s*$`)

	tagMultiSpace = regexp.MustCompile(`\s{2,}`)
	tagSpaceParen = regexp.MustCompile(`\s+([)\]}])`)
)

// CleanTag убирает рекламные ссылки на сайты/мессенджеры из одного поля.
// isTitleish=true — поле обязано остаться непустым (название/исполнитель):
// если после чистки пусто, возвращаем исходное. Для альбома isTitleish=false —
// «mp3xa.cc» как альбом законно обнулить.
func CleanTag(s string, isTitleish bool) string {
	orig := s
	s = tagBracket.ReplaceAllString(s, "")
	s = tagSocial.ReplaceAllString(s, "")
	if tagOnly.MatchString(s) {
		if isTitleish {
			return orig
		}
		return ""
	}
	s = tagTail.ReplaceAllString(s, "")
	if s == orig {
		return orig
	}
	s = tagMultiSpace.ReplaceAllString(s, " ")
	s = tagSpaceParen.ReplaceAllString(s, "$1")
	s = trimSpace(s)
	if isTitleish && s == "" {
		return orig
	}
	return s
}

// CleanTags — чистка тройки полей трека одним вызовом.
func CleanTags(artist, title, album string) (a, t, al string) {
	return CleanTag(artist, true), CleanTag(title, true), CleanTag(album, false)
}

func trimSpace(s string) string {
	// свои границы: пробелы + висящие разделители, оставшиеся от вырезанного хвоста.
	for len(s) > 0 {
		c := s[0]
		if c == ' ' || c == '\t' {
			s = s[1:]
			continue
		}
		break
	}
	for len(s) > 0 {
		c := s[len(s)-1]
		if c == ' ' || c == '\t' {
			s = s[:len(s)-1]
			continue
		}
		break
	}
	return s
}
