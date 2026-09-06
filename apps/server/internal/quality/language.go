package quality

import "unicode"

// Языки, которые Alex оставляет (разбор плеера п.7, TG 18514): русский,
// английский, немецкий, французский, итальянский. Латиница покрывает
// англ/нем/фр/итал (и заодно исп/порт/польск и т.п. — их по одному названию
// надёжно не отделить, поэтому НЕ трогаем: лучше лишнее оставить, чем удалить
// нужное). Кириллица — русский. Всё остальное письмо (CJK, арабица, иврит,
// тайское, деванагари, хангыль, греческое, армянское, грузинское) — точно вне
// списка.
var blockedScripts = []*unicode.RangeTable{
	unicode.Han, unicode.Hiragana, unicode.Katakana, unicode.Hangul,
	unicode.Arabic, unicode.Hebrew, unicode.Thai, unicode.Devanagari,
	unicode.Bengali, unicode.Tamil, unicode.Telugu, unicode.Greek,
	unicode.Armenian, unicode.Georgian, unicode.Lao, unicode.Khmer,
	unicode.Myanmar, unicode.Sinhala, unicode.Ethiopic, unicode.Cherokee,
}

// LanguageAllowed — можно ли качать/держать трек по языку названия. false —
// в названии или имени исполнителя есть буквы письма вне белого списка
// (японское, китайское, арабское и т.п.). Латиница и кириллица — всегда true.
func LanguageAllowed(artist, title string) bool {
	for _, r := range artist + " " + title {
		if !unicode.IsLetter(r) {
			continue
		}
		for _, t := range blockedScripts {
			if unicode.Is(t, r) {
				return false
			}
		}
	}
	return true
}

// GuessLanguage — грубая пометка языка для журнала чистки (п.7б): что удалили и
// на каком, предположительно, языке. Не для логики отбора — только для отчёта.
// Сначала смотрим однозначные азбуки (кана, хангыль) по всей строке, потом
// остальное: «夜に駆ける» — иероглифы + хирагана, это японский, не «китайский».
func GuessLanguage(artist, title string) string {
	s := artist + " " + title
	has := func(t *unicode.RangeTable) bool {
		for _, r := range s {
			if unicode.Is(t, r) {
				return true
			}
		}
		return false
	}
	switch {
	case has(unicode.Hiragana), has(unicode.Katakana):
		return "японский"
	case has(unicode.Hangul):
		return "корейский"
	case has(unicode.Han):
		return "китайский/японский"
	case has(unicode.Arabic):
		return "арабский"
	case has(unicode.Hebrew):
		return "иврит"
	case has(unicode.Thai):
		return "тайский"
	case has(unicode.Devanagari), has(unicode.Bengali), has(unicode.Tamil), has(unicode.Telugu):
		return "индийские языки"
	case has(unicode.Greek):
		return "греческий"
	case has(unicode.Armenian):
		return "армянский"
	case has(unicode.Georgian):
		return "грузинский"
	}
	return "не латиница/кириллица"
}
