package main

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"soundflow/server/internal/quality"
	"soundflow/server/internal/sidecar"
)

// «Плейлист по ссылке» (Alex TG 20117–20122, 20.09.2026). Alex сам вставляет ссылку на плейлист Яндекс.Музыки
// (у своего «Мне нравится» — «Поделиться»), а не программа тянет его лайки по токену. Песни показываются тем же
// списком, что «Волна» (слушать, галочки, «Скачать выбранные» — тот же POST /api/acquire). Раньше был
// GET /api/yandex/likes и раздел «Твои лайки из Яндекс.Музыки» — убраны по его ответу «2».

const maxPlaylistLink = 2048

type yandexTrackOut struct {
	YandexID    string `json:"yandex_id"`
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	CoverURL    string `json:"cover_url"`
	DurationSec int    `json:"duration_sec"`
	AlreadyHave bool   `json:"already_have"`
}

type yandexPlaylistOut struct {
	Title string           `json:"title"`
	Items []yandexTrackOut `json:"items"`
}

// hYandexPlaylist — GET /api/yandex/playlist?url=<ссылка>: песни плейлиста с пометкой already_have (уже есть в
// каталоге по artist+title — не дублируем) и без тех, что Alex убрал кнопкой «Удалить» во вкладке «Открытия».
func (s *Service) hYandexPlaylist(w http.ResponseWriter, r *http.Request) {
	link := strings.TrimSpace(r.URL.Query().Get("url"))
	if link == "" {
		http.Error(w, "Вставь ссылку на плейлист Яндекс.Музыки", 400)
		return
	}
	if len(link) > maxPlaylistLink {
		http.Error(w, "Ссылка слишком длинная — скопируй её заново из Яндекс.Музыки", 400)
		return
	}
	base := s.sidecarURL()
	if base == "" {
		http.Error(w, "качалка ещё запускается — попробуй через минуту", 503)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	title, items, err := sidecar.New(base).YandexPlaylist(ctx, link)
	if err != nil {
		var pe *sidecar.PlaylistError
		if errors.As(err, &pe) {
			http.Error(w, pe.Msg, 400) // не ссылка / закрыт / не найден — текст для Alex как есть
			return
		}
		http.Error(w, err.Error(), 502)
		return
	}
	out := make([]yandexTrackOut, 0, len(items))
	dismissed, _ := s.db.DismissedDiscover()
	for _, it := range items {
		key := quality.NormalizedKey(it.Artist, it.Title)
		have, _ := s.db.TrackExistsByKey(key)
		if !have && dismissed[key] {
			continue
		}
		out = append(out, yandexTrackOut{
			YandexID: it.YandexID, Artist: it.Artist, Title: it.Title,
			Album: it.Album, CoverURL: it.CoverURL, DurationSec: it.DurationSec,
			AlreadyHave: have,
		})
	}
	writeJSON(w, yandexPlaylistOut{Title: title, Items: out})
}
