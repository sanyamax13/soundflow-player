// Package itunes — запасной источник обложек, когда своей в файле нет и
// Яндекс.Музыка (через сайдкар) не нашла. Добавлено 05.09.2026 по просьбе
// Alex: "для песен, у которых не нашлось обложки, поищи в интернете". iTunes
// Search — открытый API без ключа, для попсы/рока обычно находит.
package itunes

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var httpClient = &http.Client{Timeout: 10 * time.Second}

// baseURL — переопределяется в тестах на локальный httptest-сервер.
var baseURL = "https://itunes.apple.com/search"

type searchResponse struct {
	Results []struct {
		ArtworkURL100 string `json:"artworkUrl100"`
	} `json:"results"`
}

// Cover — ссылка на обложку 600×600 ("" — не нашлось). Ошибка — только при
// реальном сбое сети/API, отсутствие результата это не ошибка.
func Cover(ctx context.Context, artist, title string) (string, error) {
	q := url.Values{
		"term":  {artist + " " + title},
		"media": {"music"},
		"limit": {"1"},
	}
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
	if len(out.Results) == 0 || out.Results[0].ArtworkURL100 == "" {
		return "", nil
	}
	// ".../100x100bb.jpg" → ".../600x600bb.jpg" — крупнее для полноэкранного плеера.
	return strings.Replace(out.Results[0].ArtworkURL100, "100x100bb", "600x600bb", 1), nil
}
