package api

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// «Чёрный ящик» телефона (Alex TG 21786, 26.09.2026: «очень подробный — каждый клик и
// каждое дуновение ветра»). Телефон пишет КАЖДОЕ событие (нажатия, переходы, плеер,
// сеть, батарея, ошибки, запросы к серверу) в свой журнал и пачками присылает сюда.
// Кладём как есть, построчно (JSON на строку), по дням:
//   <BlackBoxDir>/<устройство>/<ГГГГ-ММ-ДД>.jsonl
// Хранится blackBoxKeepDays дней, старое стирается само. Разбираю журналы я (Claude)
// прямо на сервере — отдельного окна не делаем.

const (
	blackBoxKeepDays = 60
	blackBoxMaxBody  = 32 << 20 // 32 МБ за раз (после распаковки) — с запасом на неделю без связи
)

var (
	blackBoxDeviceRe = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	blackBoxDayRe    = regexp.MustCompile(`"t":"(\d{4}-\d{2}-\d{2})`)
	blackBoxMu       sync.Mutex
	blackBoxCleaned  string // день последней чистки старых файлов
)

// POST /v1/blackbox?device=<id> — тело: строки JSON (можно gzip, Content-Encoding: gzip).
func (s *Server) blackBox(w http.ResponseWriter, r *http.Request) {
	if s.BlackBoxDir == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "чёрный ящик выключен"})
		return
	}
	dev := r.URL.Query().Get("device")
	if !blackBoxDeviceRe.MatchString(dev) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нет устройства"})
		return
	}
	var body io.Reader = r.Body
	if strings.EqualFold(r.Header.Get("Content-Encoding"), "gzip") {
		gz, err := gzip.NewReader(r.Body)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "битый gzip"})
			return
		}
		defer gz.Close()
		body = gz
	}
	data, err := io.ReadAll(io.LimitReader(body, blackBoxMaxBody+1))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "не прочиталось"})
		return
	}
	if len(data) > blackBoxMaxBody {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "слишком много за раз"})
		return
	}
	n, err := writeBlackBox(s.BlackBoxDir, dev, data, time.Now())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "lines": n})
}

// writeBlackBox раскладывает строки по файлам дней (день берётся из поля "t" строки;
// нет — сегодняшний) и раз в день стирает файлы старше blackBoxKeepDays.
func writeBlackBox(root, dev string, data []byte, now time.Time) (int, error) {
	blackBoxMu.Lock()
	defer blackBoxMu.Unlock()
	dir := filepath.Join(root, dev)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return 0, err
	}
	today := now.Format("2006-01-02")
	byDay := map[string]*bytes.Buffer{}
	var order []string
	n := 0
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 64<<10), 4<<20)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		day := today
		if m := blackBoxDayRe.FindSubmatch(line); m != nil {
			day = string(m[1])
		}
		b := byDay[day]
		if b == nil {
			b = &bytes.Buffer{}
			byDay[day] = b
			order = append(order, day)
		}
		b.Write(line)
		b.WriteByte('\n')
		n++
	}
	for _, day := range order {
		f, err := os.OpenFile(filepath.Join(dir, day+".jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			return n, err
		}
		_, werr := f.Write(byDay[day].Bytes())
		cerr := f.Close()
		if werr != nil {
			return n, werr
		}
		if cerr != nil {
			return n, cerr
		}
	}
	if blackBoxCleaned != today {
		blackBoxCleaned = today
		cleanOldBlackBox(root, now)
	}
	return n, nil
}

func cleanOldBlackBox(root string, now time.Time) {
	cutoff := now.AddDate(0, 0, -blackBoxKeepDays).Format("2006-01-02")
	devs, _ := os.ReadDir(root)
	for _, d := range devs {
		if !d.IsDir() {
			continue
		}
		files, _ := os.ReadDir(filepath.Join(root, d.Name()))
		for _, f := range files {
			name := f.Name()
			if strings.HasSuffix(name, ".jsonl") && strings.TrimSuffix(name, ".jsonl") < cutoff {
				_ = os.Remove(filepath.Join(root, d.Name(), name))
			}
		}
	}
}
