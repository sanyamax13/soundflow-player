package quality

import "testing"

func TestNormalizeKeyPart(t *testing.T) {
	cases := map[string]string{
		"Beyoncé":                "beyonce",
		"Sigur Rós":              "sigur ros",
		"Mötley Crüe":            "motley crue",
		"AC/DC":                  "ac dc",
		"  Multiple   Spaces  ":  "multiple spaces",
		"P!nk":                   "p nk",
		"Би-2":                   "би 2",
		"Sum 41":                 "sum 41",
		"Guns N' Roses":          "guns n roses",
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
