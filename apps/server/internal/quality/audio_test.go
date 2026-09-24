package quality

import "testing"

func TestClassifyAudio(t *testing.T) {
	cases := []struct {
		mime         string
		br           int
		wantTier     Tier
		wantPlayable bool
	}{
		{"audio/flac", 0, TierExcellent, true},
		{"audio/wav", 1411, TierExcellent, true},
		{"audio/mpeg", 0, TierUnknown, true},
		{"audio/mpeg", 96, TierBad, false},
		{"audio/mpeg", 128, TierBad, false},
		{"audio/mpeg", 191, TierBad, false},
		{"audio/mpeg", 192, TierGood, true},
		{"audio/mpeg", 256, TierGood, true},
		{"audio/mpeg", 320, TierExcellent, true},
		{"audio/mp4", 80, TierBad, false},
		{"audio/mp4", 128, TierGood, true},
		{"audio/mp4", 256, TierExcellent, true},
		{"audio/opus", 128, TierGood, true},
		{"audio/weird", 64, TierBad, false},
		{"audio/weird", 200, TierAcceptable, true},
	}
	for _, c := range cases {
		tier, playable, reason := ClassifyAudio(c.mime, c.br)
		if tier != c.wantTier || playable != c.wantPlayable {
			t.Errorf("ClassifyAudio(%q,%d) = %s/%v (%s), ждали %s/%v",
				c.mime, c.br, tier, playable, reason, c.wantTier, c.wantPlayable)
		}
	}
}

func TestCompareAndReplace(t *testing.T) {
	// mp3 320 лучше mp3 128
	if CompareAudio("audio/mpeg", 320, "audio/mpeg", 128) <= 0 {
		t.Error("320 должно быть лучше 128")
	}
	// flac лучше mp3 320
	if CompareAudio("audio/flac", 0, "audio/mpeg", 320) <= 0 {
		t.Error("flac должно быть лучше mp3 320")
	}
	// равные — 0
	if CompareAudio("audio/mpeg", 256, "audio/mpeg", 256) != 0 {
		t.Error("равные должны дать 0")
	}
	// заменяем только на строго лучшее
	if !ShouldReplace("audio/mpeg", 128, "audio/mpeg", 320) {
		t.Error("128 → 320 надо заменить")
	}
	if ShouldReplace("audio/mpeg", 320, "audio/mpeg", 320) {
		t.Error("равное заменять не надо")
	}
	if ShouldReplace("audio/flac", 0, "audio/mpeg", 320) {
		t.Error("flac на mp3 менять не надо")
	}
}

func TestMimeFromExt(t *testing.T) {
	cases := map[string]string{
		"/music/a.mp3":  "audio/mpeg",
		"/music/b.M4A":  "audio/mp4",
		"/music/c.flac": "audio/flac",
		"/music/d.xyz":  "audio/mpeg",
		"/music/e":      "audio/mpeg",
	}
	for path, want := range cases {
		if got := MimeFromExt(path); got != want {
			t.Errorf("MimeFromExt(%q) = %q, ждали %q", path, got, want)
		}
	}
}
