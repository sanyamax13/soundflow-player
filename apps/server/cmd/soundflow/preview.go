package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"soundflow/server/internal/sidecar"
)

// Прослушивание песни из вкладки «Открытия» до скачивания (Alex TG 20073, 19.09.2026: «каждую песню
// можно прослушать»). Полная песня из Яндекса: качалка (у неё токен) даёт временную прямую ссылку на
// mp3, программа отдаёт окну поток через себя — с поддержкой перемотки (Range), чтобы плеер окна
// работал так же, как с песнями каталога. Ссылка живёт недолго — держим её в памяти, чтобы не
// спрашивать качалку на каждый запрос перемотки; если Яндекс её уже не принимает — спрашиваем заново.

const previewURLTTL = 10 * time.Minute

type previewEntry struct {
	url string
	exp time.Time
}

var (
	previewMu    sync.Mutex
	previewCache = map[string]previewEntry{}
	// Общего таймаута нет — это поток; ждём только начала ответа.
	previewHTTP = &http.Client{Transport: &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		ResponseHeaderTimeout: 20 * time.Second,
	}}
)

func (s *Service) previewURL(ctx context.Context, id, artist, title string, fresh bool) (string, error) {
	key := id + "|" + artist + "|" + title
	if !fresh {
		previewMu.Lock()
		e, ok := previewCache[key]
		previewMu.Unlock()
		if ok && time.Now().Before(e.exp) {
			return e.url, nil
		}
	}
	base := s.sidecarURL()
	if base == "" {
		return "", errPreviewNoSidecar
	}
	cctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	u, err := sidecar.New(base).YandexStreamURL(cctx, id, artist, title)
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(u, "https://") && !strings.HasPrefix(u, "http://") {
		return "", errors.New("качалка вернула странную ссылку")
	}
	previewMu.Lock()
	previewCache[key] = previewEntry{url: u, exp: time.Now().Add(previewURLTTL)}
	previewMu.Unlock()
	return u, nil
}

var errPreviewNoSidecar = errors.New("качалка ещё запускается — попробуй через минуту")

// hYandexPreview — GET /api/yandex/preview?id=<yandex_id>&artist=&title=  (только с этого компьютера:
// иначе любой в домашней сети слушал бы Яндекс по токену Alex).
func (s *Service) hYandexPreview(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	id, artist, title := q.Get("id"), q.Get("artist"), q.Get("title")
	if id == "" && (artist == "" || title == "") {
		http.Error(w, "нужен id или artist и title", 400)
		return
	}
	for attempt := 0; attempt < 2; attempt++ {
		u, err := s.previewURL(r.Context(), id, artist, title, attempt == 1)
		if err != nil {
			code := 502
			if errors.Is(err, errPreviewNoSidecar) {
				code = 503
			}
			http.Error(w, err.Error(), code)
			return
		}
		req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, u, nil)
		if err != nil {
			http.Error(w, err.Error(), 502)
			return
		}
		if rg := r.Header.Get("Range"); rg != "" {
			req.Header.Set("Range", rg)
		}
		resp, err := previewHTTP.Do(req)
		if err == nil && resp.StatusCode >= 400 && attempt == 0 {
			resp.Body.Close() // ссылка протухла — спросим у качалки новую
			continue
		}
		if err != nil {
			if attempt == 0 && r.Context().Err() == nil {
				continue
			}
			http.Error(w, err.Error(), 502)
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 400 {
			http.Error(w, "Яндекс не отдал песню: "+resp.Status, 502)
			return
		}
		h := w.Header()
		ct := resp.Header.Get("Content-Type")
		if ct == "" || strings.HasPrefix(ct, "text/") || ct == "application/octet-stream" {
			ct = "audio/mpeg"
		}
		h.Set("Content-Type", ct)
		for _, k := range []string{"Content-Length", "Content-Range", "Accept-Ranges"} {
			if v := resp.Header.Get(k); v != "" {
				h.Set(k, v)
			}
		}
		if h.Get("Accept-Ranges") == "" {
			h.Set("Accept-Ranges", "bytes")
		}
		w.WriteHeader(resp.StatusCode)
		_, _ = io.Copy(w, resp.Body)
		return
	}
}
