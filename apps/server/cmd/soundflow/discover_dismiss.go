package main

import (
	"encoding/json"
	"net/http"

	"soundflow/server/internal/quality"
)

// «Удалить» во вкладке «Открытия» (Alex TG 20073, 19.09.2026). Песня пропадает из списков
// волны / лайков Яндекса / старых лайков телефона. Это ТОЛЬКО скрытие: лайк в Яндексе, лайк на
// телефоне, метка «больше не качать» и каталог не трогаются; вернуть можно (undismiss).

type discoverDismissIn struct {
	Artist string `json:"artist"`
	Title  string `json:"title"`
}

func readDiscoverDismiss(w http.ResponseWriter, r *http.Request) (key string, in discoverDismissIn, ok bool) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<16)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, err.Error(), 400)
		return "", in, false
	}
	if in.Artist == "" && in.Title == "" {
		http.Error(w, "нужны artist и title", 400)
		return "", in, false
	}
	return quality.NormalizedKey(in.Artist, in.Title), in, true
}

// hDiscoverDismiss — POST /api/discover/dismiss {artist,title}.
func (s *Service) hDiscoverDismiss(w http.ResponseWriter, r *http.Request) {
	key, in, ok := readDiscoverDismiss(w, r)
	if !ok {
		return
	}
	if err := s.db.DismissDiscover(key, in.Artist, in.Title); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// hDiscoverUndismiss — POST /api/discover/undismiss {artist,title}: «Вернуть» после «Удалить».
func (s *Service) hDiscoverUndismiss(w http.ResponseWriter, r *http.Request) {
	key, _, ok := readDiscoverDismiss(w, r)
	if !ok {
		return
	}
	if err := s.db.UndismissDiscover(key); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// dropDismissedWave — из подборки дня (она лежит в кэше целый день) убрать песни, которые Alex
// с тех пор скрыл кнопкой «Удалить».
func (s *Service) dropDismissedWave(in []yandexWaveOut) []yandexWaveOut {
	dismissed, err := s.db.DismissedDiscover()
	if err != nil || len(dismissed) == 0 {
		return in
	}
	out := make([]yandexWaveOut, 0, len(in))
	for _, it := range in {
		if !dismissed[quality.NormalizedKey(it.Artist, it.Title)] {
			out = append(out, it)
		}
	}
	return out
}
