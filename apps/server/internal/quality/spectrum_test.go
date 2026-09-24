package quality

import (
	"math"
	"testing"
)

// synthTone — несколько секунд синусоид на заданных частотах (Гц), моно,
// имитирует «музыку» с ограниченным спектром до maxHz.
func synthTone(sr int, seconds float64, freqs []float64) []float32 {
	n := int(float64(sr) * seconds)
	pcm := make([]float32, n)
	for i := range pcm {
		t := float64(i) / float64(sr)
		var v float64
		for _, f := range freqs {
			v += math.Sin(2 * math.Pi * f * t)
		}
		pcm[i] = float32(v / float64(len(freqs)) * 0.5)
	}
	return pcm
}

func TestSpectralCutoffHzDetectsLowpass(t *testing.T) {
	sr := spectrumSR
	// «Обрезанный» источник: энергия только до ~14кГц (похоже на плохой
	// исходник, даже если контейнер потом выдаёт себя за 320/FLAC).
	lowpass := synthTone(sr, 3, []float64{200, 1000, 3000, 8000, 13500})
	cutoff := SpectralCutoffHz(lowpass, sr)
	if cutoff <= 0 {
		t.Fatalf("не определили cutoff вообще")
	}
	if cutoff > 16000 {
		t.Errorf("cutoff = %.0f, ожидали заметно ниже 16000 (источник обрезан на ~13.5к)", cutoff)
	}
}

func TestSpectralCutoffHzFullBandNotFlagged(t *testing.T) {
	sr := spectrumSR
	// Полноценный источник: энергия почти до Найквиста (реальный 320/lossless).
	fullband := synthTone(sr, 3, []float64{200, 1000, 3000, 8000, 13500, 19000, 20500})
	cutoff := SpectralCutoffHz(fullband, sr)
	if cutoff < 18000 {
		t.Errorf("cutoff = %.0f, ожидали ближе к Найквисту (полный спектр)", cutoff)
	}
	if SuspiciousCutoff(TierExcellent, cutoff) {
		t.Errorf("полный спектр не должен считаться подозрительным для excellent (cutoff=%.0f)", cutoff)
	}
}

func TestSuspiciousCutoffGating(t *testing.T) {
	cases := []struct {
		tier   Tier
		cutoff float64
		want   bool
	}{
		{TierExcellent, 13500, true},  // заявлен excellent, реально ~128k-источник
		{TierExcellent, 19500, false}, // заявлен excellent, спектр полный
		{TierGood, 14000, true},       // заявлен good, реально хуже
		{TierGood, 17000, false},
		{TierAcceptable, 12000, false}, // низкий tier и так не проверяем
		{TierExcellent, 0, false},      // не определили — не отклоняем
	}
	for _, c := range cases {
		if got := SuspiciousCutoff(c.tier, c.cutoff); got != c.want {
			t.Errorf("SuspiciousCutoff(%v, %.0f) = %v, want %v", c.tier, c.cutoff, got, c.want)
		}
	}
}

func TestTierDowngrade(t *testing.T) {
	if TierExcellent.Downgrade() != TierGood {
		t.Errorf("excellent должен понижаться до good")
	}
	if TierGood.Downgrade() != TierAcceptable {
		t.Errorf("good должен понижаться до acceptable")
	}
	if TierAcceptable.Downgrade() != TierAcceptable {
		t.Errorf("acceptable не должен понижаться дальше")
	}
}
