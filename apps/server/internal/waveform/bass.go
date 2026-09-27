package waveform

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"os/exec"
	"sort"

	"soundflow/server/internal/proc"
)

// BassFPS — сколько отметок баса в секунду (одна на 50 мс).
const BassFPS = 20

// BassFromFile — «удары баса» песни для пульсации кнопки «играть» в плеере (27.09.2026, Alex:
// «от кнопки плей пульсация под басы»). Только низкие частоты (до ~150 Гц — бочка и бас-линия),
// громкость по кусочкам 50 мс, и от неё — насколько громкость ВЫРОСЛА против последних 300 мс
// (так вспыхивает удар, а не ровный гул). BassFPS байт 0..255 на секунду. Пустой/тихий → nil.
func BassFromFile(path string) ([]byte, error) {
	const sr = 2000
	cmd := proc.Quiet(exec.Command(proc.FFmpeg(),
		"-v", "error",
		"-i", path,
		"-ac", "1",
		"-af", "lowpass=f=150,lowpass=f=150",
		"-ar", fmt.Sprintf("%d", sr),
		"-f", "f32le",
		"pipe:1",
	))
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("ffmpeg: %v: %s", err, errb.String())
	}
	raw := out.Bytes()
	pcm := make([]float32, len(raw)/4)
	for i := range pcm {
		pcm[i] = math.Float32frombits(binary.LittleEndian.Uint32(raw[i*4:]))
	}
	return BassOnsets(pcm, sr), nil
}

// BassOnsets — отметки ударов из моно-семплов частоты sr (уже без высоких частот).
func BassOnsets(pcm []float32, sr int) []byte {
	win := sr / BassFPS
	n := len(pcm) / win
	if n < BassFPS { // меньше секунды
		return nil
	}
	rms := make([]float64, n)
	for i := 0; i < n; i++ {
		var s float64
		for _, x := range pcm[i*win : (i+1)*win] {
			s += float64(x) * float64(x)
		}
		rms[i] = math.Sqrt(s / float64(win))
	}
	on := make([]float64, n)
	const back = 6 // 300 мс
	for i := range rms {
		var m float64
		k := 0
		for j := i - back; j < i; j++ {
			if j >= 0 {
				m += rms[j]
				k++
			}
		}
		if k > 0 {
			m /= float64(k)
		}
		if d := rms[i] - m; d > 0 {
			on[i] = d
		}
	}
	sorted := append([]float64(nil), on...)
	sort.Float64s(sorted)
	top := sorted[int(float64(len(sorted)-1)*0.98)]
	if top <= 1e-6 {
		return nil
	}
	b := make([]byte, n)
	for i, v := range on {
		x := v / top
		if x > 1 {
			x = 1
		}
		b[i] = byte(math.Round(x * 255))
	}
	return b
}
