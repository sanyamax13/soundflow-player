package api

import (
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"soundflow/server/internal/db"
)

// Прогресс докачки музыки на телефон «прямо сейчас». Живёт только в памяти
// сервера: при рестарте сбрасывается — это нормально, телефон при следующей
// докачке пришлёт заново. В БД не пишем (эфемерно, часто меняется).

type downloadTracker struct {
	mu sync.Mutex
	m  map[string]db.DownloadProgress
}

func newDownloadTracker() *downloadTracker {
	return &downloadTracker{m: make(map[string]db.DownloadProgress)}
}

func (t *downloadTracker) set(deviceID string, p db.DownloadProgress) {
	t.mu.Lock()
	defer t.mu.Unlock()
	p.UpdatedAt = time.Now()
	if !p.Active {
		delete(t.m, deviceID) // «докачка кончилась» — забыть строку
		return
	}
	t.m[deviceID] = p
}

func (t *downloadTracker) get(deviceID string) *db.DownloadProgress {
	t.mu.Lock()
	defer t.mu.Unlock()
	p, ok := t.m[deviceID]
	if !ok {
		return nil
	}
	// Телефон отвалился, не прислал «готово» — через 2 минуты тишины забываем,
	// чтобы в окне не висело «качает…» вечно.
	if time.Since(p.UpdatedAt) > 2*time.Minute {
		delete(t.m, deviceID)
		return nil
	}
	pp := p
	return &pp
}

func (s *Server) dl() *downloadTracker {
	s.dlOnce.Do(func() { s.dlTracker = newDownloadTracker() })
	return s.dlTracker
}

// DownloadProgress — сколько песен из пачки телефон уже забрал прямо сейчас.
// nil, если телефон ничего не качает. Зовёт окно (cmd/soundflow) для строки
// «качает: <песня>, 45 из 200».
func (s *Server) DownloadProgress(deviceID string) *db.DownloadProgress {
	return s.dl().get(deviceID)
}

// POST /v1/sync/progress — телефон в цикле «Докачать ещё» шлёт, сколько песен
// из текущей пачки уже скачал. Тело: {device_id, done, total, current, active}.
func (s *Server) syncProgress(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID string `json:"device_id"`
		Done     int    `json:"done"`
		Total    int    `json:"total"`
		Current  string `json:"current"`
		Active   bool   `json:"active"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.DeviceID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен device_id"})
		return
	}
	s.dl().set(req.DeviceID, db.DownloadProgress{
		Done:    req.Done,
		Total:   req.Total,
		Current: req.Current,
		Active:  req.Active,
	})
	writeJSON(w, http.StatusOK, map[string]string{"ok": "1"})
}
