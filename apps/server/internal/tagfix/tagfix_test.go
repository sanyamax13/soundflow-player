package tagfix

import "testing"

func TestSanitize_Latin1AsCP1251(t *testing.T) {
	// Реальные примеры из боевой базы (Alex TG 14.09.2026, сборники с
	// торрентов «100 HITS REMIX» / «Поп-хиты зимы»).
	cases := map[string]string{
		"Íþøà":      "Нюша",
		"Ä. Áèëàí":  "Д. Билан",
		"ÂÈÀ «Ãðà»": "ВИА «Гра»",
		"Гр. «Джинсовые мальчики»": "Гр. «Джинсовые мальчики»", // уже нормальный — не трогаем
		"":         "",
		"A. Shine": "A. Shine", // чистая латиница — не трогаем
	}
	for in, want := range cases {
		got := Sanitize(in)
		if got != want {
			t.Errorf("Sanitize(%q) = %q, хотел %q", in, got, want)
		}
	}
}

func TestSanitize_DoesNotMangleRealAccentedNames(t *testing.T) {
	// Настоящее имя с одним акцентом не должно превращаться в кириллицу —
	// после раскодирования получилось бы меньше половины кириллических
	// букв, порог должен это отсечь.
	for _, name := range []string{"Beyoncé", "Mötley Crüe", "Sigur Rós"} {
		if got := Sanitize(name); got != name {
			t.Errorf("Sanitize(%q) = %q, не должно было измениться", name, got)
		}
	}
}

func TestSanitize_MixedCyrillicAndEnglishRemixSuffix(t *testing.T) {
	// «Семь морей (New Energy mix)» — доля кириллицы в целой строке ниже
	// 50% из-за длинной англоязычной приписки, но кириллица тут есть и
	// её надо починить (Alex TG 14.09.2026, сборник «100 HITS REMIX»).
	in := "Ñåìü ìîðåé (New Energy mix)"
	want := "Семь морей (New Energy mix)"
	if got := Sanitize(in); got != want {
		t.Errorf("Sanitize(%q) = %q, хотел %q", in, got, want)
	}
}

func TestSanitize_InvalidUTF8CP1251Bytes(t *testing.T) {
	// Старый вид порчи (пункт 1) — сырые байты cp1251, невалидный UTF-8 сам
	// по себе. 0xCD 0xFE 0xF8 0xE0 = "Нюша" в Windows-1251.
	raw := string([]byte{0xCD, 0xFE, 0xF8, 0xE0})
	if got := Sanitize(raw); got != "Нюша" {
		t.Errorf("Sanitize(raw cp1251) = %q, хотел Нюша", got)
	}
}

func TestCleanArtist(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Гр. «Отпетые мошенники»", "Отпетые мошенники"},
		{"Гр. «Джинсовые мальчики»", "Джинсовые мальчики"},
		{"ВИА «Гра» (Н. Грановская, А. Джанабаева, В. Брежнева)", "ВИА Гра"},
		{"В.  Левкин и Гульназ", "В. Левкин & Гульназ"},
		{"Гр. «Размер Project»", "Размер Project"},
		{"Д. Билан", "Д. Билан"},
		{"Гречка", "Гречка"},
		{"Группа крови", "Группа крови"},
	}
	for _, c := range cases {
		if got := CleanArtist(c.in); got != c.want {
			t.Errorf("CleanArtist(%q) = %q, ждал %q", c.in, got, c.want)
		}
	}
}

func TestJoinArtists(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Noah/Erik Elias", "Noah & Erik Elias"},
		{"В.  Левкин и Гульназ", "В. Левкин & Гульназ"},
		{"Illenium; Teddy Swims", "Illenium & Teddy Swims"},
		{"Armin van Buuren X Lucas & Steve Feat.  Josh Cumbee", "Armin van Buuren & Lucas & Steve feat. Josh Cumbee"},
		{"Peter Bjorn And John", "Peter Bjorn And John"},
		{"Simon & Garfunkel", "Simon & Garfunkel"},
		{"Earth, Wind & Fire", "Earth, Wind & Fire"},
		{"Tyler, The Creator", "Tyler, The Creator"},
		{"AC/DC", "AC/DC"},
		{"25/17", "25/17"},
		{"Wallows, Clairo", "Wallows & Clairo"},
		{"Malcolm X", "Malcolm X"},
		{"ILLENIUM ft. Tom Grennan", "ILLENIUM feat. Tom Grennan"},
		{"Король и Шут", "Король и Шут"},
		{"С. Пьеха и Г. Лепс", "С. Пьеха & Г. Лепс"},
		{"TOMORROW X TOGETHER", "TOMORROW X TOGETHER"},
		{"Lil Wayne; X Ambassadors", "Lil Wayne & X Ambassadors"},
		{"Kygo X Whitney Houston", "Kygo & Whitney Houston"},
		{"Captain Hollywood x Eddie G, Malyx", "Captain Hollywood & Eddie G & Malyx"},
		{"Alan Walker & Isabella Melkman & Katherine O&#039;Ryan", "Alan Walker & Isabella Melkman & Katherine O'Ryan"},
	}
	for _, c := range cases {
		if got := CleanArtist(c.in); got != c.want {
			t.Errorf("CleanArtist(%q) = %q, ждал %q", c.in, got, c.want)
		}
	}
}
