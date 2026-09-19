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

	"soundflow/server/internal/proc"
)

// SampleRate — CNN14 обучена на 32 кГц моно.
const SampleRate = 32000

// minSamples — CNN14 разваливается на очень коротком входе (мел-пулинг уводит
// число кадров в ноль). ~2 с тишины гарантируют, что граф отработает.
const minSamples = 2 * SampleRate

// DecodePCM декодирует любой аудиофайл (mp3/flac/m4a/…) в моно-PCM float32
// 32 кГц. Ресемплинг — soxr (высокое качество), это важно: грубый ресемплер
// смещает спектр и отпечаток (проверено на шаге 0). Нужен ffmpeg: рядом с программой
// или в PATH (см. proc.FFmpeg).
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
	data = stripID3BeforeRIFF(data)
	cmd := proc.Quiet(exec.Command(proc.FFmpeg(),
		"-v", "error",
		"-i", "pipe:0",
		"-ac", "1",
		"-ar", fmt.Sprintf("%d", SampleRate),
		"-af", "aresample=resampler=soxr:precision=28",
		"-f", "f32le",
		"pipe:1",
	))
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

// stripID3BeforeRIFF — у части файлов (по расширению .mp3) в начале тег ID3v2,
// а сразу за ним не MP3, а WAV («RIFF…WAVE»). ffmpeg такое не открывает ни из
// pipe, ни по пути («invalid start code ID3[3] in RIFF header»), и у песни нет
// отпечатка (19.09.2026: так было у трёх из 97 песен без отпечатка). Отрезаем
// тег — дальше обычный WAV. Всё остальное возвращает как есть.
func stripID3BeforeRIFF(data []byte) []byte {
	if len(data) < 14 || string(data[:3]) != "ID3" {
		return data
	}
	for _, b := range data[6:10] { // размер тега — 4 байта по 7 бит
		if b&0x80 != 0 {
			return data
		}
	}
	off := 10 + (int(data[6])<<21 | int(data[7])<<14 | int(data[8])<<7 | int(data[9]))
	if data[5]&0x10 != 0 { // есть «футер» тега
		off += 10
	}
	if off+12 > len(data) {
		return data
	}
	if string(data[off:off+4]) == "RIFF" && string(data[off+8:off+12]) == "WAVE" {
		return data[off:]
	}
	return data
}

func padMin(pcm []float32) []float32 {
	if len(pcm) >= minSamples {
		return pcm
	}
	out := make([]float32, minSamples)
	copy(out, pcm)
	return out
}
