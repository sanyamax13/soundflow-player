// Package music — выдача аудиофайлов на этапе каркаса.
// Если задан SOUNDFLOW_MUSIC_DIR с файлами — отдаём их; иначе несколько
// сгенерированных тонов, чтобы «Поток» было чем наполнить без укладки
// бинарников в репозиторий.
package music

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type Track struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Artist string `json:"artist"`
	Format string `json:"format"`
}

type Service struct {
	dir string
}

func New(musicDir string) *Service { return &Service{dir: musicDir} }

var audioExt = map[string]bool{".mp3": true, ".m4a": true, ".flac": true, ".wav": true, ".ogg": true}

// Встроенные тестовые тоны — пока нет каталога. Дают очередь для «Потока».
var testTones = []struct {
	id   string
	freq float64
}{
	{"test-tone", 440},
	{"test-tone-2", 554},
	{"test-tone-3", 659},
}

func toneFreq(id string) (float64, bool) {
	for _, t := range testTones {
		if t.id == id {
			return t.freq, true
		}
	}
	return 0, false
}

// List — что можно забрать с сервера.
func (s *Service) List() []Track {
	files := s.scan()
	if len(files) == 0 {
		out := make([]Track, 0, len(testTones))
		for _, t := range testTones {
			out = append(out, Track{
				ID:     t.id,
				Title:  fmt.Sprintf("Тестовый тон %.0f Гц", t.freq),
				Artist: "SoundFlow",
				Format: "wav",
			})
		}
		return out
	}
	out := make([]Track, 0, len(files))
	for _, f := range files {
		name := strings.TrimSuffix(filepath.Base(f), filepath.Ext(f))
		out = append(out, Track{
			ID:     name,
			Title:  name,
			Artist: "локальная папка",
			Format: strings.TrimPrefix(filepath.Ext(f), "."),
		})
	}
	return out
}

// ServeFile — отдать аудио по id. Range поддерживается через http.ServeContent.
func (s *Service) ServeFile(w http.ResponseWriter, r *http.Request, id string) {
	if freq, ok := toneFreq(id); ok || s.dir == "" {
		if !ok {
			freq = 440
		}
		w.Header().Set("Content-Type", "audio/wav")
		http.ServeContent(w, r, id+".wav", time.Time{}, bytes.NewReader(testTone(freq)))
		return
	}
	for _, f := range s.scan() {
		if strings.TrimSuffix(filepath.Base(f), filepath.Ext(f)) == id {
			http.ServeFile(w, r, f)
			return
		}
	}
	http.Error(w, "нет такого трека", http.StatusNotFound)
}

func (s *Service) scan() []string {
	if s.dir == "" {
		return nil
	}
	var out []string
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if audioExt[strings.ToLower(filepath.Ext(e.Name()))] {
			out = append(out, filepath.Join(s.dir, e.Name()))
		}
	}
	sort.Strings(out)
	return out
}

// testTone — 3 секунды синуса заданной частоты, WAV PCM 16 бит, моно 22050.
func testTone(freq float64) []byte {
	const (
		rate = 22050
		secs = 3
	)
	n := rate * secs
	buf := new(bytes.Buffer)
	dataLen := n * 2
	buf.WriteString("RIFF")
	binary.Write(buf, binary.LittleEndian, uint32(36+dataLen))
	buf.WriteString("WAVEfmt ")
	binary.Write(buf, binary.LittleEndian, uint32(16))
	binary.Write(buf, binary.LittleEndian, uint16(1))      // PCM
	binary.Write(buf, binary.LittleEndian, uint16(1))      // моно
	binary.Write(buf, binary.LittleEndian, uint32(rate))   // sample rate
	binary.Write(buf, binary.LittleEndian, uint32(rate*2)) // byte rate
	binary.Write(buf, binary.LittleEndian, uint16(2))      // block align
	binary.Write(buf, binary.LittleEndian, uint16(16))     // bits
	buf.WriteString("data")
	binary.Write(buf, binary.LittleEndian, uint32(dataLen))
	for i := 0; i < n; i++ {
		v := math.Sin(2 * math.Pi * freq * float64(i) / rate)
		binary.Write(buf, binary.LittleEndian, int16(v*0.3*math.MaxInt16))
	}
	return buf.Bytes()
}
