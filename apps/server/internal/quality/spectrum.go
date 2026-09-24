package quality

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"math/cmplx"
	"os/exec"

	"soundflow/server/internal/proc"
)

// «Поддельный 320»/фейк-lossless: заголовок/битрейт можно подделать
// (перекодировать плохой источник в высокий битрейт или в FLAC), реальный
// звук — нет. У настоящего 320kbps/lossless высокие частоты почти не
// обрезаны; у файла, реально взятого из ~128kbps источника, encoder срезал
// всё выше ~16кГц — это видно по спектру, даже если контейнер потом
// пересжали в 320/FLAC. Alex TG 24.09.2026: «по спектру тоже будем
// проверять» (после вебресерча — известная дыра, есть готовые инструменты
// вроде spek/flaccheck, тут — минимальная своя версия под наш pipeline).

const spectrumSR = 44100 // Найквист 22050 — с запасом покрывает 15-20кГц

// CutoffFromFile — декодит файл через ffmpeg (моно, 44.1кГц) и считает
// частоту среза спектра. 0 — не удалось определить (тишина/слишком
// короткий/ffmpeg упал) — вызывающий код не должен на этом отклонять файл,
// только «не знаем».
func CutoffFromFile(path string) (float64, error) {
	cmd := proc.Quiet(exec.Command(proc.FFmpeg(),
		"-v", "error",
		"-i", path,
		"-ac", "1",
		"-ar", fmt.Sprintf("%d", spectrumSR),
		"-f", "f32le",
		"pipe:1",
	))
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return 0, fmt.Errorf("ffmpeg: %v: %s", err, errb.String())
	}
	raw := out.Bytes()
	n := len(raw) / 4
	if n < spectrumWindow*2 {
		return 0, nil // слишком короткий кусок для приличного окна
	}
	pcm := make([]float32, n)
	for i := range pcm {
		pcm[i] = math.Float32frombits(binary.LittleEndian.Uint32(raw[i*4:]))
	}
	return SpectralCutoffHz(pcm, spectrumSR), nil
}

const spectrumWindow = 4096 // ~93мс при 44.1кГц, разрешение ~10.8 Гц/бин
const spectrumFrames = 6    // несколько окон по треку — устойчивее к тишине/паузам

// SpectralCutoffHz — частота, выше которой в спектре практически нет
// энергии (Гц). 0 — не определили (тишина по всему треку). Усредняет
// несколько окон из середины трека (первые/последние 10% пропускаем —
// вступления/затухания часто тише и не показательны).
func SpectralCutoffHz(pcm []float32, sampleRate int) float64 {
	if len(pcm) < spectrumWindow*2 {
		return 0
	}
	lo := len(pcm) / 10
	hi := len(pcm) - len(pcm)/10
	usable := hi - lo
	if usable < spectrumWindow {
		lo, hi, usable = 0, len(pcm), len(pcm)
	}

	mag := make([]float64, spectrumWindow/2)
	frames := 0
	step := usable / spectrumFrames
	if step < spectrumWindow {
		step = spectrumWindow
	}
	for start := lo; start+spectrumWindow <= hi; start += step {
		m := magnitudeSpectrum(pcm[start : start+spectrumWindow])
		for i, v := range m {
			mag[i] += v
		}
		frames++
		if frames >= spectrumFrames {
			break
		}
	}
	if frames == 0 {
		return 0
	}
	for i := range mag {
		mag[i] /= float64(frames)
	}

	// Опорный уровень — пик в «густонаселённой» середине спектра
	// (0.5–4кГц), где у музыки почти всегда есть энергия.
	binHz := float64(sampleRate) / float64(spectrumWindow)
	refLo, refHi := int(500/binHz), int(4000/binHz)
	if refHi >= len(mag) {
		refHi = len(mag) - 1
	}
	peak := 0.0
	for i := refLo; i <= refHi; i++ {
		if mag[i] > peak {
			peak = mag[i]
		}
	}
	if peak <= 1e-9 {
		return 0 // тишина
	}
	peakDB := 20 * math.Log10(peak)

	// Идём от Найквиста вниз, ищем первый бин, где энергия ещё заметна
	// относительно опорного пика (-45дБ — за этим порогом это уже шум
	// квантования/кодека, не реальный музыкальный сигнал).
	const thresholdDB = -45
	for i := len(mag) - 1; i >= refHi; i-- {
		db := 20 * math.Log10(mag[i]+1e-12)
		if db-peakDB > thresholdDB {
			return float64(i) * binHz
		}
	}
	return 0
}

// magnitudeSpectrum — окно Ханна + FFT, первая половина (0..Найквист).
func magnitudeSpectrum(frame []float32) []float64 {
	n := len(frame)
	c := make([]complex128, n)
	for i, s := range frame {
		w := 0.5 - 0.5*math.Cos(2*math.Pi*float64(i)/float64(n-1)) // Hann
		c[i] = complex(float64(s)*w, 0)
	}
	fft(c)
	out := make([]float64, n/2)
	for i := range out {
		out[i] = cmplx.Abs(c[i])
	}
	return out
}

// fft — итеративный radix-2 Cooley-Tukey на месте. len(a) должна быть
// степенью двойки (spectrumWindow = 4096 — подходит).
func fft(a []complex128) {
	n := len(a)
	for i, j := 1, 0; i < n; i++ {
		bit := n >> 1
		for ; j&bit != 0; bit >>= 1 {
			j ^= bit
		}
		j ^= bit
		if i < j {
			a[i], a[j] = a[j], a[i]
		}
	}
	for length := 2; length <= n; length <<= 1 {
		ang := -2 * math.Pi / float64(length)
		wlen := cmplx.Exp(complex(0, ang))
		for i := 0; i < n; i += length {
			w := complex(1, 0)
			for j := 0; j < length/2; j++ {
				u := a[i+j]
				v := a[i+j+length/2] * w
				a[i+j] = u + v
				a[i+j+length/2] = u - v
				w *= wlen
			}
		}
	}
}

// SuspiciousCutoff — похоже ли, что заявленный tier завышен относительно
// реального спектра («поддельный 320» / фейк-lossless). cutoffHz<=0 —
// не определили, не отклоняем (playable остаётся как решил ClassifyAudio).
func SuspiciousCutoff(tier Tier, cutoffHz float64) bool {
	if cutoffHz <= 0 {
		return false
	}
	switch tier {
	case TierExcellent:
		return cutoffHz < 18500
	case TierGood:
		return cutoffHz < 16000
	default:
		return false // acceptable/bad и так низкий tier, спектр не проверяем
	}
}

// Downgrade — на ступень ниже (для случая SuspiciousCutoff). Acceptable
// остаётся Acceptable — ниже уже No (по битрейту это и так отбраковано
// раньше, до спектральной проверки не доходит).
func (t Tier) Downgrade() Tier {
	switch t {
	case TierExcellent:
		return TierGood
	case TierGood:
		return TierAcceptable
	default:
		return t
	}
}
