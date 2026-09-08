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
	cmd := exec.Command("ffmpeg",
		"-v", "error",
		"-i", path,
		"-ac", "1",
		"-ar", fmt.Sprintf("%d", decodeSR),
		"-f", "f32le",
		"pipe:1",
	)
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
func Bars(pcm []float32, n int) []byte {
	if n <= 0 || len(pcm) < n {
		return nil
	}
	raw := make([]float64, n)
	peak := 0.0
	for i := 0; i < n; i++ {
		lo := i * len(pcm) / n
		hi := (i + 1) * len(pcm) / n
		var sum float64
		for _, s := range pcm[lo:hi] {
			sum += float64(s) * float64(s)
		}
		r := math.Sqrt(sum / float64(hi-lo))
		raw[i] = r
		if r > peak {
			peak = r
		}
	}
	if peak <= 1e-6 {
		return nil
	}
	out := make([]byte, n)
	for i, r := range raw {
		// гамма 0.6 приподнимает тихие места, /peak — нормировка.
		v := math.Pow(r/peak, 0.6)
		// низ подрезаем на 0.08, чтобы совсем тихие места не были в ноль.
		v = 0.08 + 0.92*v
		if v > 1 {
			v = 1
		}
		out[i] = byte(math.Round(v * 255))
	}
	return out
}
