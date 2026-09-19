package inference

import (
	"bytes"
	"encoding/binary"
	"math"
	"os/exec"
	"testing"
)

// tinyWAV — секунда синуса, моно 16 бит 8 кГц.
func tinyWAV() []byte {
	const rate, secs = 8000, 1
	n := rate * secs
	var pcm bytes.Buffer
	for i := 0; i < n; i++ {
		binary.Write(&pcm, binary.LittleEndian, int16(8000*math.Sin(2*math.Pi*440*float64(i)/rate)))
	}
	var w bytes.Buffer
	w.WriteString("RIFF")
	binary.Write(&w, binary.LittleEndian, uint32(36+pcm.Len()))
	w.WriteString("WAVEfmt ")
	binary.Write(&w, binary.LittleEndian, uint32(16))
	binary.Write(&w, binary.LittleEndian, uint16(1))    // PCM
	binary.Write(&w, binary.LittleEndian, uint16(1))    // моно
	binary.Write(&w, binary.LittleEndian, uint32(rate)) // частота
	binary.Write(&w, binary.LittleEndian, uint32(rate*2))
	binary.Write(&w, binary.LittleEndian, uint16(2))
	binary.Write(&w, binary.LittleEndian, uint16(16))
	w.WriteString("data")
	binary.Write(&w, binary.LittleEndian, uint32(pcm.Len()))
	w.Write(pcm.Bytes())
	return w.Bytes()
}

// id3 — тег ID3v2.3 с телом bodySize байт (размер пишется по 7 бит).
func id3(bodySize int) []byte {
	h := []byte{'I', 'D', '3', 3, 0, 0,
		byte(bodySize >> 21 & 0x7f), byte(bodySize >> 14 & 0x7f), byte(bodySize >> 7 & 0x7f), byte(bodySize & 0x7f)}
	return append(h, make([]byte, bodySize)...)
}

func TestStripID3BeforeRIFF(t *testing.T) {
	wav := tinyWAV()
	glued := append(id3(1234), wav...)

	if got := stripID3BeforeRIFF(glued); !bytes.Equal(got, wav) {
		t.Errorf("тег перед WAV должен быть отрезан: len=%d, ждал %d", len(got), len(wav))
	}
	// ID3 + не WAV (обычный mp3 с тегом) — не трогаем
	mp3ish := append(id3(50), []byte{0xff, 0xfb, 0x90, 0x00, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10}...)
	if got := stripID3BeforeRIFF(mp3ish); !bytes.Equal(got, mp3ish) {
		t.Error("mp3 с тегом менять нельзя")
	}
	// без тега и обрезанные входы — как есть
	for _, in := range [][]byte{wav, []byte("ID3"), id3(10), nil} {
		if got := stripID3BeforeRIFF(in); !bytes.Equal(got, in) {
			t.Errorf("вход %d байт изменился", len(in))
		}
	}
	// битый размер (старший бит) — не трогаем
	bad := append([]byte{}, glued...)
	bad[7] |= 0x80
	if got := stripID3BeforeRIFF(bad); !bytes.Equal(got, bad) {
		t.Error("битый размер тега: вход не должен меняться")
	}
}

// Сквозная проверка с настоящим ffmpeg: WAV с приклеенным ID3 раньше не
// открывался («invalid start code ID3[3] in RIFF header»), теперь декодируется.
func TestDecodePCMBytesWAVWithID3(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("нет ffmpeg в PATH")
	}
	pcm, err := DecodePCMBytes(append(id3(4000), tinyWAV()...))
	if err != nil {
		t.Fatalf("WAV с ID3 должен декодироваться: %v", err)
	}
	if len(pcm) < minSamples {
		t.Errorf("слишком мало отсчётов: %d", len(pcm))
	}
}
