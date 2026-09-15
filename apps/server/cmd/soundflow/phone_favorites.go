// Alex TG 15.09.2026: «в избранном на телефоне есть песни [из старой,
// стёртой библиотеки], хотелось бы что бы они остались — приложение
// увидит лайки и скачает эти песни, и весь процесс я хочу видеть».
//
// Телефон уже не хранит сами файлы этих треков — только название и что
// они были лайкнуты. Телефон и комп раньше общались в одну сторону (комп
// решает, что скачать на телефон) — здесь добавлен обратный, узкий канал:
// телефон присылает список лайков, комп сам решает, чего из них не хватает
// в каталоге, и показывает это в «Открытия» рядом с лайками Яндекса —
// докачка тем же /api/acquire, прогресс виден так же, как везде.
package main

import (
	"encoding/json"
	"net/http"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/quality"
)

type phoneFavoritesIn struct {
	Tracks []struct {
		Artist string `json:"artist"`
		Title  string `json:"title"`
	} `json:"tracks"`
}

// hPhoneFavoritesReport — POST /api/phone/favorites (с телефона).
func (s *Service) hPhoneFavoritesReport(w http.ResponseWriter, r *http.Request) {
	var in phoneFavoritesIn
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	items := make([]localdb.MissingFavorite, 0, len(in.Tracks))
	for _, t := range in.Tracks {
		if t.Artist == "" && t.Title == "" {
			continue
		}
		items = append(items, localdb.MissingFavorite{
			NormalizedKey: quality.NormalizedKey(t.Artist, t.Title),
			Artist:        t.Artist, Title: t.Title,
		})
	}
	if err := s.db.ReportMissingFavorites(items); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

type missingFavoriteOut struct {
	Artist string `json:"artist"`
	Title  string `json:"title"`
}

// hPhoneFavoritesMissing — GET /api/phone/missing-favorites (для окна на
// компе, вкладка «Открытия»).
func (s *Service) hPhoneFavoritesMissing(w http.ResponseWriter, r *http.Request) {
	items, err := s.db.ListMissingFavorites()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	out := make([]missingFavoriteOut, len(items))
	for i, it := range items {
		out[i] = missingFavoriteOut{Artist: it.Artist, Title: it.Title}
	}
	writeJSON(w, out)
}
