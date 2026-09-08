package main

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"soundflow/server/internal/acquire"
	"soundflow/server/internal/sidecar"
)

// «Найти трек» из окна: артист+название → качалка (Python-дочерний процесс) →
// трек скачан и добавлен в каталог → телефон подхватит при следующей синхре.
// Долгое (минуты), поэтому запускаем фоном и показываем последние попытки.

type acqEntry struct {
	Artist string    `json:"artist"`
	Title  string    `json:"title"`
	State  string    `json:"state"` // idle | running | done | fail
	Note   string    `json:"note"`
	At     time.Time `json:"at"`
}

type acqTracker struct {
	mu   sync.Mutex
	list []acqEntry // новые в конце, держим последние 20
}

func (t *acqTracker) add(artist, title string) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.list = append(t.list, acqEntry{Artist: artist, Title: title, State: "running", Note: "ищу…", At: time.Now()})
	if len(t.list) > 20 {
		t.list = t.list[len(t.list)-20:]
	}
	return len(t.list) - 1
}

func (t *acqTracker) set(i int, state, note string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if i >= 0 && i < len(t.list) {
		t.list[i].State = state
		t.list[i].Note = note
		t.list[i].At = time.Now()
	}
}

func (t *acqTracker) snapshot() []acqEntry {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]acqEntry, len(t.list))
	copy(out, t.list)
	// новые сверху
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

func (s *Service) acq() *acqTracker {
	s.acqOnce.Do(func() { s.acqT = &acqTracker{} })
	return s.acqT
}

// acquireService — собрать acquire.Service поверх текущей качалки. nil — качалка
// ещё не готова.
func (s *Service) acquireService() *acquire.Service {
	url := s.dl.URL()
	if url == "" || s.store == nil {
		return nil
	}
	return &acquire.Service{
		DB: s.store,
		Finder: &localFinder{
			Client: sidecar.New(url),
			eng:    s.eng,
			pm:     s.pm,
		},
	}
}

// POST /api/acquire?artist=..&title=..  — запустить поиск+скачивание.
func (s *Service) hAcquire(w http.ResponseWriter, r *http.Request) {
	artist := strings.TrimSpace(r.URL.Query().Get("artist"))
	title := strings.TrimSpace(r.URL.Query().Get("title"))
	if artist == "" || title == "" {
		http.Error(w, "нужны artist и title", 400)
		return
	}
	svc := s.acquireService()
	if svc == nil {
		http.Error(w, "качалка ещё запускается — попробуй через минуту", 503)
		return
	}
	idx := s.acq().add(artist, title)
	_ = s.db.AddServerLog("info", artist, title, "поиск и скачивание запущены", 0)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
		defer cancel()
		res, err := svc.Acquire(ctx, acquire.Request{Artist: artist, Title: title})
		switch {
		case err == nil && res.Created:
			s.acq().set(idx, "done", "скачано: "+res.Source+" · "+res.QualityTier)
			_ = s.db.AddServerLog("added", artist, title, "скачано ("+res.Source+")", 0)
			// Отпечаток — фоном, не держим ответ. Нет движка/ffmpeg — трек
			// просто не попадёт в умное радио, не ошибка.
			go func(id string) {
				bg, c := context.WithTimeout(context.Background(), 6*time.Minute)
				defer c()
				if e := svc.AnalyzeAndStore(bg, id); e != nil {
					s.db.AddServerLog("info", artist, title, "отпечаток не посчитан: "+e.Error(), 0) //nolint:errcheck
				}
			}(res.TrackID)
		case err == nil && !res.Created:
			s.acq().set(idx, "done", "уже было в каталоге")
			_ = s.db.AddServerLog("info", artist, title, "уже в каталоге", 0)
		case errors.Is(err, acquire.ErrNotFound):
			s.acq().set(idx, "fail", "не нашёл ни на одном источнике")
			_ = s.db.AddServerLog("error", artist, title, "не найдено", 0)
		default:
			note := "ошибка"
			if res.Reason != "" {
				note = res.Reason
			} else if err != nil {
				note = err.Error()
			}
			s.acq().set(idx, "fail", note)
			_ = s.db.AddServerLog("error", artist, title, note, 0)
		}
	}()
	writeJSON(w, map[string]any{"queued": true})
}

// GET /api/acquire/log — последние попытки «Найти трек» для окна.
func (s *Service) hAcquireLog(w http.ResponseWriter, r *http.Request) {
	ready := s.dl.URL() != "" && s.store != nil
	writeJSON(w, map[string]any{"ready": ready, "items": s.acq().snapshot()})
}
