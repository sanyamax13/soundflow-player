package quality

import "testing"

func TestLanguageAllowed(t *testing.T) {
	cases := []struct {
		artist, title string
		want          bool
	}{
		{"Земфира", "Искала", true},
		{"Radiohead", "Creep", true},
		{"Rammstein", "Sonne", true},
		{"Édith Piaf", "Non, je ne regrette rien", true},
		{"YOASOBI", "夜に駆ける", false},
		{"방탄소년단", "봄날", false},
		{"Fairuz", "زهرة المدائن", false},
		{"Mohammad Reza Shajarian", "مرغ سحر", false},
		{"Static-X", "Push It", true},
	}
	for _, c := range cases {
		if got := LanguageAllowed(c.artist, c.title); got != c.want {
			t.Errorf("LanguageAllowed(%q, %q) = %v, ждали %v", c.artist, c.title, got, c.want)
		}
	}
}

func TestGuessLanguage(t *testing.T) {
	if g := GuessLanguage("YOASOBI", "夜に駆ける"); g != "японский" {
		t.Errorf("японское название → %q", g)
	}
	if g := GuessLanguage("방탄소년단", "봄날"); g != "корейский" {
		t.Errorf("корейское название → %q", g)
	}
}
