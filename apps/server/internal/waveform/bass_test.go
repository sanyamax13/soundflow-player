package waveform

import (
	"math"
	"testing"
)

// Бочка раз в полсекунды на тихом гуле — отметки высокие в начале каждого удара, низкие между.
func TestBassOnsets(t *testing.T) {
	const sr = 2000
	pcm := make([]float32, sr*4)
	for i := range pcm {
		v := 0.05 * math.Sin(2*math.Pi*60*float64(i)/sr)
		if i%(sr/2) < sr/20 {
			v += 0.8 * math.Sin(2*math.Pi*55*float64(i)/sr)
		}
		pcm[i] = float32(v)
	}
	b := BassOnsets(pcm, sr)
	if len(b) != 4*BassFPS {
		t.Fatalf("len = %d", len(b))
	}
	if b[10] < 200 || b[5] > 30 {
		t.Errorf("удар %d, между ударами %d", b[10], b[5])
	}
}
