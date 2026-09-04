package quality

import "testing"

func TestScreenRejectsLiveAndJunk(t *testing.T) {
	cases := []struct {
		title  string
		wantOK bool
	}{
		// студийные — пропускаем
		{"Bohemian Rhapsody", true},
		{"Rolling in the Deep", true},
		{"Богемская рапсодия", true},
		// каверы и ремиксы — пропускаем (нужны)
		{"Believer (Rock Cover)", true},
		{"Blinding Lights (Chromatics Remix)", true},
		{"Song Title - Acoustic", true},
		// live — режем только как маркер версии
		{"Wish You Were Here (Live)", false},
		{"Numb [Live]", false},
		{"Hotel California - Live at the Forum", false},
		{"Song Title (Live in London)", false},
		{"Комната (концертная версия)", false},
		// «live» как часть имени — НЕ режем
		{"Live Is Life", true},
		{"Livewire", true},
		{"Deliver Me", true},
		// откровенный мусор — режем всегда
		{"Shape of You (Karaoke Version)", false},
		{"Песня (Караоке)", false},
		{"Faded (Nightcore)", false},
		{"Someone Like You - Slowed + Reverb", false},
		{"Nothing Else Matters (Instrumental)", false},
		{"Track (sped up)", false},
		// не песни вообще — режем (найдено на реальной библиотеке 04.09.2026:
		// интервью Laura Branigan затесалось в музыку под видом трека)
		{"The Hot Ones (Self Control Era) (Interview)", false},
		{"Артист (Интервью Афише)", false},
		{"Weekly Podcast Episode 12", false},
		{"Movie Trailer", false},
		{"My Ringtone", false},
	}
	for _, c := range cases {
		got := Screen("Artist", c.title, "")
		if got.OK != c.wantOK {
			t.Errorf("Screen(%q).OK = %v (%s), ждали %v", c.title, got.OK, got.Reason, c.wantOK)
		}
	}
}

func TestScreenLiveInSourceURL(t *testing.T) {
	if Screen("A", "Normal Title", "https://youtube.com/watch?v=live-at-wembley").OK {
		t.Error("live в URL должен зарезать")
	}
	if !Screen("A", "Normal Title", "https://music.yandex.ru/track/12345").OK {
		t.Error("обычный URL резать не должен")
	}
}

func TestReleaseKind(t *testing.T) {
	cases := []struct{ title, album, want string }{
		{"Bohemian Rhapsody", "A Night at the Opera", "studio"},
		{"Imagine - 2010 Remaster", "", "remaster"},
		{"Come Together (Remastered 2009)", "", "remaster"},
		{"Levels (Skrillex Remix)", "", "remix"},
		{"Layla (Acoustic)", "", "acoustic"},
		{"Enter Sandman (Instrumental)", "", "instrumental"},
		{"Wonderwall (Live at Wembley)", "", "live"},
		{"Yesterday (Demo)", "", "demo"},
	}
	for _, c := range cases {
		if got := ReleaseKind(c.title, c.album); got != c.want {
			t.Errorf("ReleaseKind(%q,%q) = %q, ждали %q", c.title, c.album, got, c.want)
		}
	}
}

func TestExplicitAndClean(t *testing.T) {
	explicit := []string{"HUMBLE. (Explicit)", "Track [E]", "Song - Explicit Version"}
	for _, s := range explicit {
		if !IsExplicit(s) {
			t.Errorf("IsExplicit(%q) = false", s)
		}
	}
	if IsExplicit("Regular Song") {
		t.Error("ложное срабатывание IsExplicit")
	}
	if IsExplicit("Extra Life") {
		t.Error("«Extra» не должно ловиться как explicit")
	}
	if !IsCleanVersion("HUMBLE. (Clean)") {
		t.Error("IsCleanVersion не поймал")
	}
}

func TestDurationMatch(t *testing.T) {
	if !DurationMatch(200, 210, false, false).OK {
		t.Error("Δ10s должно совпасть")
	}
	if DurationMatch(200, 260, false, false).OK {
		t.Error("Δ60s без доверенного источника — не совпасть")
	}
	if !DurationMatch(200, 250, true, false).OK {
		t.Error("Δ50s с доверенным источником (ремастер) — совпасть")
	}
	if DurationMatch(200, 250, true, true).OK {
		t.Error("Δ50s с bad keyword — не совпасть даже у доверенного")
	}
	if !DurationMatch(0, 250, false, false).OK {
		t.Error("нет эталона — считаем совпавшим")
	}
}
