// Package sidecar — HTTP-клиент к старому Python-сайдкару (yt-dlp, Яндекс,
// musify, торренты). Сайдкар живёт на fg (D:\soundflow-app), слушает 8001,
// его не переписываем. Go-сервер дёргает нужные ручки.
package sidecar

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Client struct {
	base string
	http *http.Client
}

func New(baseURL string) *Client {
	return &Client{
		base: baseURL,
		// Скачивание трека через цепочку источников — минуты. Таймаут щедрый.
		http: &http.Client{Timeout: 8 * time.Minute},
	}
}

func (c *Client) post(ctx context.Context, path string, body, out any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+path, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("sidecar %s: %d %s", path, resp.StatusCode, bytes.TrimSpace(data))
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(data, out)
}

func (c *Client) get(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+path, nil)
	if err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("sidecar %s: %d %s", path, resp.StatusCode, bytes.TrimSpace(data))
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(data, out)
}

// Health — жив ли сайдкар.
func (c *Client) Health(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+"/health", nil)
	if err != nil {
		return err
	}
	hc := &http.Client{Timeout: 5 * time.Second}
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("sidecar health: %d", resp.StatusCode)
	}
	return nil
}

// FindAudioResult — что вернул /find-audio. FilePath — КАНОНИЧЕСКИЙ путь.
type FindAudioResult struct {
	Found       bool   `json:"found"`
	FilePath    string `json:"file_path"`
	BitrateKbps int    `json:"bitrate_kbps"`
	DurationSec int    `json:"duration_sec"`
	SizeBytes   int64  `json:"size_bytes"`
	Source      string `json:"source"`
	ProviderURL string `json:"provider_url"`
}

// FindAudio — поиск+скачивание через цепочку (Яндекс 320 → musify → торренты).
// skipProviders — какие источники не трогать (мы всегда гасим soundcloud,
// youtube_music, soulseek). expectedDurationSec 0 — сайдкар сам спросит Яндекс.
func (c *Client) FindAudio(ctx context.Context, artist, title string, expectedDurationSec int, skipProviders []string) (FindAudioResult, error) {
	body := map[string]any{
		"artist":         artist,
		"title":          title,
		"skip_providers": skipProviders,
	}
	if expectedDurationSec > 0 {
		body["expected_duration_sec"] = expectedDurationSec
	}
	var out FindAudioResult
	err := c.post(ctx, "/find-audio", body, &out)
	return out, err
}

// YandexArtist — артист из Яндекс.Музыки: имя, фото, топ-треки.
type YandexArtist struct {
	Found     bool   `json:"found"`
	Name      string `json:"name"`
	PhotoURL  string `json:"photo_url"`
	TopTracks []struct {
		Title       string `json:"title"`
		DurationSec int    `json:"duration_sec"`
	} `json:"top_tracks"`
}

func (c *Client) YandexSearchArtist(ctx context.Context, name string) (YandexArtist, error) {
	var out YandexArtist
	err := c.post(ctx, "/yandex/search-artist", map[string]any{"name": name, "with_tracks": true}, &out)
	return out, err
}

// ID3Info — артист и название из тегов файла (канонический путь; сайдкар сам
// переведёт в реальный). Пусто если тегов нет.
func (c *Client) ID3Info(ctx context.Context, canonicalPath string) (artist, title string, err error) {
	var out struct {
		Artist string `json:"artist"`
		Title  string `json:"title"`
	}
	err = c.post(ctx, "/id3-info", map[string]any{"file_path": canonicalPath}, &out)
	return out.Artist, out.Title, err
}

// AnalyzeFeatures — «звуковой отпечаток» файла: 2048-мерный вектор PANNs CNN14
// (penultimate layer). Канонический путь; сайдкар сам переведёт в реальный.
// nil без ошибки — если сайдкар не смог посчитать. Медленно: секунды на трек.
func (c *Client) AnalyzeFeatures(ctx context.Context, canonicalPath string) ([]float32, error) {
	var out struct {
		Found     bool      `json:"found"`
		Embedding []float32 `json:"embedding"`
	}
	if err := c.post(ctx, "/analyze-features", map[string]any{"file_path": canonicalPath}, &out); err != nil {
		return nil, err
	}
	if !out.Found || len(out.Embedding) == 0 {
		return nil, nil
	}
	return out.Embedding, nil
}

// YandexTrackCover — URL обложки трека в Яндекс.Музыке ("" если не нашлась).
func (c *Client) YandexTrackCover(ctx context.Context, artist, title string) (string, error) {
	var out struct {
		Found    bool   `json:"found"`
		CoverURL string `json:"cover_url"`
	}
	if err := c.post(ctx, "/yandex/track-cover", map[string]any{"artist": artist, "title": title}, &out); err != nil {
		return "", err
	}
	return out.CoverURL, nil
}

// YandexLikeItem — трек «Мне нравится» личного аккаунта (Alex TG 14.09.2026).
type YandexLikeItem struct {
	YandexID    string `json:"yandex_id"`
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	CoverURL    string `json:"cover_url"`
	DurationSec int    `json:"duration_sec"`
}

// YandexLikes — все треки «Мне нравится». Ошибка сети/сайдкара — err; "нет
// токена" сайдкар возвращает как error-строку в теле, тоже приходит через err.
func (c *Client) YandexLikes(ctx context.Context) ([]YandexLikeItem, error) {
	var out struct {
		Items []YandexLikeItem `json:"items"`
		Error string           `json:"error"`
	}
	if err := c.get(ctx, "/yandex/likes", &out); err != nil {
		return nil, err
	}
	if out.Error != "" {
		return nil, fmt.Errorf("sidecar yandex/likes: %s", out.Error)
	}
	return out.Items, nil
}

// YandexDislikeItem — трек «Не рекомендовать» (для чёрного списка).
type YandexDislikeItem struct {
	Artist string `json:"artist"`
	Title  string `json:"title"`
}

// YandexWaveItem — сырой кандидат «Волны» (артист/жанр/похожие артисты —
// НЕ личная рекомендация Яндекса, см. cmd/soundflow/yandex_wave.go).
type YandexWaveItem struct {
	YandexID    string `json:"yandex_id"`
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	CoverURL    string `json:"cover_url"`
	DurationSec int    `json:"duration_sec"`
	Genre       string `json:"genre"`
	Source      string `json:"source"` // artist | genre | similar_artist
}

// YandexWaveCandidates — extraArtists: артисты, залайканные на ТЕЛЕФОНЕ
// (Alex TG 15.09.2026: «не только Яндекс, но и то, что лайкнул на телефоне»),
// подмешиваются в пул наравне с топ-артистами по Яндекс-лайкам.
func (c *Client) YandexWaveCandidates(ctx context.Context, extraArtists []string) ([]YandexWaveItem, error) {
	var out struct {
		Items []YandexWaveItem `json:"items"`
		Error string           `json:"error"`
	}
	path := "/yandex/wave-candidates"
	if len(extraArtists) > 0 {
		path += "?extra_artists=" + url.QueryEscape(strings.Join(extraArtists, ","))
	}
	if err := c.get(ctx, path, &out); err != nil {
		return nil, err
	}
	if out.Error != "" {
		return nil, fmt.Errorf("sidecar yandex/wave-candidates: %s", out.Error)
	}
	return out.Items, nil
}

func (c *Client) YandexDislikes(ctx context.Context) ([]YandexDislikeItem, error) {
	var out struct {
		Items []YandexDislikeItem `json:"items"`
		Error string              `json:"error"`
	}
	if err := c.get(ctx, "/yandex/dislikes", &out); err != nil {
		return nil, err
	}
	if out.Error != "" {
		return nil, fmt.Errorf("sidecar yandex/dislikes: %s", out.Error)
	}
	return out.Items, nil
}
