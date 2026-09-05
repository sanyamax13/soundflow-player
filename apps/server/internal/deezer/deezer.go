// Package deezer — третий (запасной) источник обложек, когда своей в файле
// нет и не нашлось ни у Яндекс.Музыки, ни у iTunes. Добавлено 05.09.2026 по
// просьбе Alex после того, как iTunes-догон почти ничего не добавил (7 из
// 1673): "надо сделать веб-ресерч чтобы найти все обложки". Deezer Search —
// открытый API без ключа, MusicBrainz для сравнения оказался недоступен
// (заблокирован) и с brain, и с fg — проверено напрямую перед выбором.
package deezer

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"time"
)

var httpClient = &http.Client{Timeout: 10 * time.Second}

// baseURL — переопределяется в тестах на локальный httptest-сервер.
var baseURL = "https://api.deezer.com/search"

type searchResponse struct {
	Data []struct {
		Album struct {
			CoverXL string `json:"cover_xl"`
		} `json:"album"`
	} `json:"data"`
}

// Cover — ссылка на обложку альбома 1000×1000 ("" — не нашлось). Ошибка —
// только при реальном сбое сети/API, отсутствие результата это не ошибка.
// Как и в internal/itunes, берём первый результат без сверки исполнителя —
// поиск Deezer сам сортирует по релевантности, на пробном запросе (Dr. Dre
// — What's The Difference) первым же результатом пришёл верный альбом.
func Cover(ctx context.Context, artist, title string) (string, error) {
	q := url.Values{"q": {artist + " " + title}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		baseURL+"?"+q.Encode(), nil)
	if err != nil {
		return "", err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", nil // не 200 (в т.ч. троттлинг) — просто "не нашли", не валим весь догон
	}
	var out searchResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if len(out.Data) == 0 || out.Data[0].Album.CoverXL == "" {
		return "", nil
	}
	return out.Data[0].Album.CoverXL, nil
}
