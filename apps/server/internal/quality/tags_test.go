package quality

import "testing"

func TestCleanTag(t *testing.T) {
	cases := []struct {
		in        string
		titleish  bool
		want      string
	}{
		// скобки с сайтом
		{"Волк (Topmuzon.net)", true, "Волк"},
		{"Это любовь [gazgolder.com]", true, "Это любовь"},
		{"Ты Богиня моря! (Muzkach.net)", true, "Ты Богиня моря!"},
		{"24K Magic (mp3-you.net)", true, "24K Magic"},
		{"OneRepublic [drivemusic.me]", true, "OneRepublic"},
		// хвост
		{"Best Hits and Remixes CD by www.2baksa.net", false, "Best Hits and Remixes CD"},
		{"Коллекция минусовок! www.plus-msk.ru", false, "Коллекция минусовок!"},
		// соцсети
		{"розовая могила t.me/cupsize_all", true, "розовая могила"},
		{"Sound Clinic instagram.com/soundclinic", false, "Sound Clinic"},
		// поле целиком = сайт
		{"mp3xa.cc", false, ""},
		{"drivemusic.me", false, ""},
		{"mp3xa.cc", true, "mp3xa.cc"}, // title не обнуляем
		// не трогаем нормальное
		{"Sweet Child O' Mine", true, "Sweet Child O' Mine"},
		{"Jump (2015 Remaster)", true, "Jump (2015 Remaster)"},
		{"Song 2", true, "Song 2"},
		{"The Great Gig in the Sky", true, "The Great Gig in the Sky"},
		{"plus-msk.ru city sound", true, "plus-msk.ru city sound"}, // домен не как тег — не трогаем середину
		{"", true, ""},
	}
	for _, c := range cases {
		got := CleanTag(c.in, c.titleish)
		if got != c.want {
			t.Errorf("CleanTag(%q, %v) = %q, want %q", c.in, c.titleish, got, c.want)
		}
	}
}

func TestCleanTagsTriple(t *testing.T) {
	a, ti, al := CleanTags("21 Savage [mp3xa.cc]", "Redrum", "mp3xa.cc")
	if a != "21 Savage" || ti != "Redrum" || al != "" {
		t.Errorf("CleanTags = %q / %q / %q", a, ti, al)
	}
}

func TestStripLeadingTrackNumber(t *testing.T) {
	cases := []struct{ in, want string }{
		{"04. DJ Vertigo", "DJ Vertigo"},
		{"12) Adriano Celentano", "Adriano Celentano"},
		{"21 Savage", "21 Savage"},     // без точки/скобки — не трогаем
		{"50 Cent", "50 Cent"},         // не трогаем
		{"3 Doors Down", "3 Doors Down"},
		{"DJ Dave", "DJ Dave"},
		{"04.", "04."}, // после срезки пусто — возвращаем исходное
	}
	for _, c := range cases {
		if got := StripLeadingTrackNumber(c.in); got != c.want {
			t.Errorf("StripLeadingTrackNumber(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestIsGenericTrackTitle(t *testing.T) {
	yes := []string{"Track 4", "Track 04", "track4", "Трек 7", "ТРЕК 07", "Track_12"}
	no := []string{"Trackin'", "Track of my Tears", "Oxygene", "", "Track"}
	for _, s := range yes {
		if !IsGenericTrackTitle(s) {
			t.Errorf("IsGenericTrackTitle(%q) = false, want true", s)
		}
	}
	for _, s := range no {
		if IsGenericTrackTitle(s) {
			t.Errorf("IsGenericTrackTitle(%q) = true, want false", s)
		}
	}
}
