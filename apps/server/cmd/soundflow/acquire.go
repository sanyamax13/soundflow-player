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
	"soundflow/server/internal/waveform"
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
	url := s.sidecarURL()
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
		_, _, reason := s.downloaderState()
		if reason == "" {
			reason = "качалка ещё запускается — попробуй через минуту"
		}
		http.Error(w, reason, 503)
		return
	}
	idx := s.acq().add(artist, title)
	aj := s.jobs.beginAmbient("acquire", "Скачиваю: "+artist+" — "+title)
	_ = s.db.AddServerLog("info", artist, title, "поиск и скачивание запущены", 0)
	go func() {
		// 45 минут, а не 12: торрент-заходы идут по одной очереди (torrentSlot), песня может ждать своей очереди
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Minute)
		defer cancel()
		res, err := svc.Acquire(ctx, acquire.Request{Artist: artist, Title: title})
		switch {
		case err == nil && res.Created:
			note := "скачано: " + res.Source + " · " + res.QualityTier
			s.acq().set(idx, "done", note)
			s.jobs.finishAmbient(aj, note)
			_ = s.db.AddServerLog("added", artist, title, "скачано ("+res.Source+")", 0)
			s.onTrackAdded(res.TrackID)
			// Отпечаток — фоном, не держим ответ. Нет движка/ffmpeg — трек
			// просто не попадёт в умное радио, не ошибка.
			go func(id string) {
				bg, c := context.WithTimeout(context.Background(), 6*time.Minute)
				defer c()
				if e := svc.AnalyzeAndStore(bg, id); e != nil {
					s.db.AddServerLog("info", artist, title, "отпечаток не посчитан: "+e.Error(), 0) //nolint:errcheck
				}
				// рельеф громкости для полоски плеера (дешёвый декод, отдельно)
				if p, ok, _ := s.store.TrackFilePath(bg, id); ok {
					if wf, e := waveform.FromFile(s.pm.ToLocal(p), waveform.DefaultBars); e == nil && len(wf) > 0 {
						_ = s.store.SetWaveform(bg, id, wf)
					}
				}
			}(res.TrackID)
		case err == nil && !res.Created:
			s.acq().set(idx, "done", "уже было в каталоге")
			s.jobs.finishAmbient(aj, "уже было в каталоге")
			_ = s.db.AddServerLog("info", artist, title, "уже в каталоге", 0)
		case errors.Is(err, acquire.ErrNotFound):
			s.acq().set(idx, "fail", "не нашёл ни на одном источнике")
			s.jobs.finishAmbient(aj, "не нашёл ни на одном источнике")
			_ = s.db.AddServerLog("error", artist, title, "не найдено", 0)
		default:
			note := "ошибка"
			if res.Reason != "" {
				note = res.Reason
			} else if err != nil {
				note = err.Error()
			}
			s.acq().set(idx, "fail", note)
			s.jobs.finishAmbient(aj, note)
			_ = s.db.AddServerLog("error", artist, title, note, 0)
		}
	}()
	writeJSON(w, map[string]any{"queued": true})
}

// GET /api/acquire/log — последние попытки «Найти трек» для окна.
func (s *Service) hAcquireLog(w http.ResponseWriter, r *http.Request) {
	ready := s.sidecarURL() != "" && s.store != nil
	_, permanent, reason := s.downloaderState()
	writeJSON(w, map[string]any{
		"ready":     ready,
		"available": s.dl != nil, // false — качалки нет в этой копии, не появится за этот запуск
		"permanent": permanent,
		"reason":    reason,
		"items":     s.acq().snapshot(),
	})
}
