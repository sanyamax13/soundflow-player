package waveform

import (
	"math"
	"testing"
)

func TestBarsShape(t *testing.T) {
	// синус нарастающей амплитуды: первый столбик тихий, последний громкий.
	sr := 32000
	pcm := make([]float32, sr*4)
	for i := range pcm {
		env := float64(i) / float64(len(pcm)) // 0..1
		pcm[i] = float32(env * math.Sin(2*math.Pi*440*float64(i)/float64(sr)))
	}
	b := Bars(pcm, 32)
	if len(b) != 32 {
		t.Fatalf("len=%d", len(b))
	}
	if b[0] >= b[31] {
		t.Errorf("ожидал рост: b[0]=%d b[31]=%d", b[0], b[31])
	}
	if b[31] < 240 {
		t.Errorf("пик должен упираться в потолок, b[31]=%d", b[31])
	}
}

func TestBarsSilenceAndTooShort(t *testing.T) {
	if Bars(make([]float32, 32000), 32) != nil {
		t.Error("тишина должна дать nil")
	}
	if Bars([]float32{0.1, 0.2}, 32) != nil {
		t.Error("слишком короткий вход должен дать nil")
	}
	if Bars(nil, 32) != nil {
		t.Error("nil должен дать nil")
	}
}
