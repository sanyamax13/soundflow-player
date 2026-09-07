// Package inference — звуковой отпечаток трека (PANNs CNN14) на Go: декод аудио
// через ffmpeg + прогон ONNX-графа через onnxruntime.dll. Заменяет
// Python-сайдкар для расчёта feature_vector.
package inference

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"os/exec"
)

// SampleRate — CNN14 обучена на 32 кГц моно.
const SampleRate = 32000

// minSamples — CNN14 разваливается на очень коротком входе (мел-пулинг уводит
// число кадров в ноль). ~2 с тишины гарантируют, что граф отработает.
const minSamples = 2 * SampleRate

// DecodePCM декодирует любой аудиофайл (mp3/flac/m4a/…) в моно-PCM float32
// 32 кГц. Ресемплинг — soxr (высокое качество), это важно: грубый ресемплер
// смещает спектр и отпечаток (проверено на шаге 0). Требует ffmpeg в PATH.
//
// Файл читаем в Go и подаём ffmpeg в stdin (pipe:0): так неважно, что в пути
// кириллица/юникод — на Windows консольный ffmpeg не открывает такие пути
// (системная кодовая страница cp1251).
func DecodePCM(path string) ([]float32, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return DecodePCMBytes(data)
}

// DecodePCMBytes — то же, но из уже прочитанных байт файла.
func DecodePCMBytes(data []byte) ([]float32, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("пустой вход")
	}
	cmd := exec.Command("ffmpeg",
		"-v", "error",
		"-i", "pipe:0",
		"-ac", "1",
		"-ar", fmt.Sprintf("%d", SampleRate),
		"-af", "aresample=resampler=soxr:precision=28",
		"-f", "f32le",
		"pipe:1",
	)
	cmd.Stdin = bytes.NewReader(data)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("ffmpeg: %v: %s", err, errb.String())
	}
	raw := out.Bytes()
	if len(raw) < 4 {
		return nil, fmt.Errorf("ffmpeg: пустой поток на выходе")
	}
	n := len(raw) / 4
	pcm := make([]float32, n)
	for i := 0; i < n; i++ {
		pcm[i] = math.Float32frombits(binary.LittleEndian.Uint32(raw[i*4:]))
	}
	return padMin(pcm), nil
}

func padMin(pcm []float32) []float32 {
	if len(pcm) >= minSamples {
		return pcm
	}
	out := make([]float32, minSamples)
	copy(out, pcm)
	return out
}
