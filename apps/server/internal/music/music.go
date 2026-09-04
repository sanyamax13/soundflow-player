// Package music — выдача аудиофайлов на этапе каркаса.
// Если задан SOUNDFLOW_MUSIC_DIR с файлами — отдаём их; иначе один
// сгенерированный тон, чтобы «одна песня доставалась с сервера» работало
// без укладки бинарника в репозиторий.
package music

import (
	"bytes"
	"encoding/binary"
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

// List — что можно забрать с сервера.
func (s *Service) List() []Track {
	files := s.scan()
	if len(files) == 0 {
		return []Track{{ID: "test-tone", Title: "Тестовый тон 440 Гц", Artist: "SoundFlow", Format: "wav"}}
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
	if id == "test-tone" || s.dir == "" {
		w.Header().Set("Content-Type", "audio/wav")
		http.ServeContent(w, r, "test-tone.wav", time.Time{}, bytes.NewReader(testTone()))
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

// testTone — 2 секунды синуса 440 Гц, WAV PCM 16 бит, моно 22050.
func testTone() []byte {
	const (
		rate = 22050
		secs = 2
		freq = 440.0
	)
	n := rate * secs
	buf := new(bytes.Buffer)
	dataLen := n * 2
	buf.WriteString("RIFF")
	binary.Write(buf, binary.LittleEndian, uint32(36+dataLen))
	buf.WriteString("WAVEfmt ")
	binary.Write(buf, binary.LittleEndian, uint32(16))
	binary.Write(buf, binary.LittleEndian, uint16(1))     // PCM
	binary.Write(buf, binary.LittleEndian, uint16(1))     // моно
	binary.Write(buf, binary.LittleEndian, uint32(rate))  // sample rate
	binary.Write(buf, binary.LittleEndian, uint32(rate*2)) // byte rate
	binary.Write(buf, binary.LittleEndian, uint16(2))     // block align
	binary.Write(buf, binary.LittleEndian, uint16(16))    // bits
	buf.WriteString("data")
	binary.Write(buf, binary.LittleEndian, uint32(dataLen))
	for i := 0; i < n; i++ {
		v := math.Sin(2 * math.Pi * freq * float64(i) / rate)
		binary.Write(buf, binary.LittleEndian, int16(v*0.3*math.MaxInt16))
	}
	return buf.Bytes()
}
