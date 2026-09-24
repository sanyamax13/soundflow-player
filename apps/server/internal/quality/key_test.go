package quality

import "testing"

func TestNormalizeKeyPart(t *testing.T) {
	cases := map[string]string{
		"Beyoncé":               "beyonce",
		"Sigur Rós":             "sigur ros",
		"Mötley Crüe":           "motley crue",
		"AC/DC":                 "ac dc",
		"  Multiple   Spaces  ": "multiple spaces",
		"P!nk":                  "p nk",
		"Би-2":                  "би 2",
		"Sum 41":                "sum 41",
		"Guns N' Roses":         "guns n roses",
	}
	for in, want := range cases {
		if got := NormalizeKeyPart(in); got != want {
			t.Errorf("NormalizeKeyPart(%q) = %q, ждали %q", in, got, want)
		}
	}
}

func TestNormalizedKeyDedup(t *testing.T) {
	a := NormalizedKey("Beyoncé", "Halo")
	b := NormalizedKey("beyonce", "HALO")
	if a != b {
		t.Errorf("ключи должны совпасть: %q vs %q", a, b)
	}
	if NormalizedKey("Adele", "Hello") == NormalizedKey("Adele", "Skyfall") {
		t.Error("разные названия — разные ключи")
	}
}

// TestFuzzyKeyRealDuplicates — 15 пар, реально найденных в каталоге Alex
// 24.09.2026 (одна и та же песня, добавленная дважды под разным написанием).
func TestFuzzyKeyRealDuplicates(t *testing.T) {
	pairs := [][4]string{
		{"Katy Perry", "Hot N Cold", "Katy Perry", "Hot N Cold (Album Version)"},
		{"DjShark", "Это всё (Red Line & M1CH3L P Radio Remix)", "Dj Shark", "Это всё (Red Line & M1CH3L P Radio Remix)"},
		{"Linkin Park", "Numb", "Linkin Park", "Numb (Album Version)"},
		{"K’Naan", "Wavin’ Flag", "K'naan", "Wavin' Flag (Album Version)"},
		{"Coldplay", "Paradise", "Coldplay", "Paradise (Radio Edit)"},
		{"Rihanna", "Don't Stop The Music", "Rihanna", "Don't Stop The Music (Album Version)"},
		{"BLEU SOLEIL & LUIZA", "Soleil Bleu", "Bleu Soleil & Luiza", "Soleil Bleu (Radio Edit)"},
		{"One Republic", "All The Right Moves", "OneRepublic", "All The Right Moves"},
		{"Kristinia DeBarge", "Goodbye", "Kristinia DeBarge", "Goodbye (Album Version)"},
		{"One Republic", "Good Life", "OneRepublic", "Good Life (Album Version)"},
		{"Robin Schulz feat. Alida", "In Your Eyes (feat. Alida)", "Robin Schulz feat. Alida", "In Your Eyes"},
		{"Alok, Alan Walker feat. KIDDO", "Headlights (feat. KIDDO)", "Alok & Alan Walker Feat. Kiddo", "Headlights"},
		{"HUGEL; Topic; Arash; Daecolm", "I Adore You", "HUGEL/Topic/Arash/Daecolm", "I Adore You (feat. Daecolm)"},
		{"Jean-louis Aubert", "Tout Y Est", "Jean-Louis Aubert", "Tout Y Est (Radio Edit)"},
		{"Юрий Шатунов", "Седая ночь (InVoice Remix)", "Юрий Шатунов", "Седая ночь (In Voice Remix)"},
	}
	for _, p := range pairs {
		a, b := FuzzyKey(p[0], p[1]), FuzzyKey(p[2], p[3])
		if a != b {
			t.Errorf("FuzzyKey(%q,%q)=%q != FuzzyKey(%q,%q)=%q — должны были совпасть", p[0], p[1], a, p[2], p[3], b)
		}
	}
}

func TestFuzzyKeyStillDistinguishesRealDifferentSongs(t *testing.T) {
	if FuzzyKey("Adele", "Hello") == FuzzyKey("Adele", "Skyfall") {
		t.Error("разные названия — разные ключи")
	}
	if FuzzyKey("Linkin Park", "Numb") == FuzzyKey("Hybrid Theory, DEEPROT", "Like That") {
		t.Error("разные исполнители — разные ключи, даже если оба содержат «Hybrid Theory»/похоже звучат")
	}
	// «(Live)»/«(Remix)»/«(Acoustic)» — другая запись, не срезаем.
	if FuzzyKey("Artist", "Song (Live)") == FuzzyKey("Artist", "Song") {
		t.Error("(Live) — это другая запись, ключи не должны совпасть")
	}
}
