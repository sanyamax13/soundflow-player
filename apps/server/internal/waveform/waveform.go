// Package waveform считает компактный «рельеф громкости» трека для полоски
// перемотки в плеере (Alex TG 18979/18994: столбики должны быть реальной
// формой песни, а не случайными). N значений 0..255 = RMS по N отрезкам,
// с гамма-подъёмом тихих мест и нормировкой на пик.
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

// DefaultBars — сколько столбиков в полоске плеера.
const DefaultBars = 64

// decodeSR — форму громкости считаем на низкой частоте: 8 кГц моно хватает
// для огибающей и декодится в разы быстрее полного отпечатка (и без soxr).
const decodeSR = 8000

// FromFile — рельеф громкости прямо из аудиофайла (mp3/flac/m4a/…) через
// ffmpeg. Отдельно от inference.DecodePCM: тут дешёвый декод только под
// полоску, без ресемпла высокой точности. Пустой/битый → nil, nil.
func FromFile(path string, bars int) ([]byte, error) {
	if bars <= 0 {
		bars = DefaultBars
	}
	cmd := proc.Quiet(exec.Command(proc.FFmpeg(),
		"-v", "error",
		"-i", path,
		"-ac", "1",
		"-ar", fmt.Sprintf("%d", decodeSR),
		"-f", "f32le",
		"pipe:1",
	))
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("ffmpeg: %v: %s", err, errb.String())
	}
	raw := out.Bytes()
	if len(raw) < 4*bars {
		return nil, nil
	}
	pcm := make([]float32, len(raw)/4)
	for i := range pcm {
		pcm[i] = math.Float32frombits(binary.LittleEndian.Uint32(raw[i*4:]))
	}
	return Bars(pcm, bars), nil
}

// Bars — N байт 0..255. pcm — моно-семплы (любая частота). Пустой/тихий
// вход → nil (полоска в плеере откатится на прежний вид).
//
// Растягиваем по перцентилям (5%..95%), а не просто /пик: у зажатых
// современных записей RMS почти ровный, и без растяжки полоска выглядит
// забором. Так у каждой песни виден свой рельеф (как в SoundCloud).
func Bars(pcm []float32, n int) []byte {
	if n <= 0 || len(pcm) < n {
		return nil
	}
	raw := make([]float64, n)
	for i := 0; i < n; i++ {
		lo := i * len(pcm) / n
		hi := (i + 1) * len(pcm) / n
		var sum float64
		for _, s := range pcm[lo:hi] {
			sum += float64(s) * float64(s)
		}
		raw[i] = math.Sqrt(sum / float64(hi-lo))
	}

	sorted := append([]float64(nil), raw...)
	sort.Float64s(sorted)
	lo := sorted[len(sorted)*5/100]
	hi := sorted[len(sorted)*95/100]
	if hi-lo <= 1e-7 {
		if hi <= 1e-6 {
			return nil // тишина
		}
		lo = 0 // почти ровный трек — растягиваем от нуля
	}

	out := make([]byte, n)
	for i, r := range raw {
		v := (r - lo) / (hi - lo)
		if v < 0 {
			v = 0
		}
		if v > 1 {
			v = 1
		}
		v = math.Pow(v, 0.75)  // лёгкий подъём тихих мест
		v = 0.10 + 0.90*v      // низ не в ноль, чтобы столбик был виден
		out[i] = byte(math.Round(v * 255))
	}
	return out
}
