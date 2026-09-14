package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"soundflow/server/internal/db"
	"soundflow/server/internal/quality"
)

// Режим 2 «Торренты — обзор». Окно: артист → список релизов с трекеров
// (без скачивания) → Alex выбирает → качаем альбом через qBittorrent, треки
// в каталог. Всю грязь (трекеры, curl_cffi, qBT) делает Python-качалка;
// здесь — проксирование и добавление скачанного альбома в каталог.

type torCand struct {
	Tracker     string `json:"tracker"`
	ForumURL    string `json:"forum_url"`
	DLRef       string `json:"dl_ref"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	Year        int    `json:"year"`
	Fmt         string `json:"fmt"`
	BitrateKbps int    `json:"bitrate_kbps"`
	SizeBytes   int64  `json:"size_bytes"`
	Seeders     int    `json:"seeders"`
	Leechers    int    `json:"leechers"`
}

type torJob struct {
	Tracker string    `json:"tracker"`
	Title   string    `json:"title"`
	State   string    `json:"state"` // running | done | fail
	Note    string    `json:"note"`
	At      time.Time `json:"at"`
}

type torTracker struct {
	mu   sync.Mutex
	list []torJob
}

func (t *torTracker) add(tracker, title string) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.list = append(t.list, torJob{Tracker: tracker, Title: title, State: "running", Note: "качаю альбом…", At: time.Now()})
	if len(t.list) > 15 {
		t.list = t.list[len(t.list)-15:]
	}
	return len(t.list) - 1
}

func (t *torTracker) set(i int, state, note string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if i >= 0 && i < len(t.list) {
		t.list[i].State, t.list[i].Note, t.list[i].At = state, note, time.Now()
	}
}

func (t *torTracker) snapshot() []torJob {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]torJob, len(t.list))
	copy(out, t.list)
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

func (s *Service) tor() *torTracker {
	s.torOnce.Do(func() { s.torT = &torTracker{} })
	return s.torT
}

// dlPost — POST json на ручку качалки, вернуть тело. "" url → качалка не готова.
func (s *Service) dlPost(ctx context.Context, path string, body any, timeout time.Duration) ([]byte, error) {
	url := s.sidecarURL()
	if url == "" {
		_, _, reason := s.downloaderState()
		if reason == "" {
			reason = "качалка ещё запускается"
		}
		return nil, fmt.Errorf("%s", reason)
	}
	buf, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url+path, bytes.NewReader(buf))
	req.Header.Set("Content-Type", "application/json")
	cl := &http.Client{Timeout: timeout}
	resp, err := cl.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("качалка %d: %s", resp.StatusCode, bytes.TrimSpace(b))
	}
	return b, nil
}

// POST /api/torrent/search?artist=..&album=..
func (s *Service) hTorrentSearch(w http.ResponseWriter, r *http.Request) {
	artist := strings.TrimSpace(r.URL.Query().Get("artist"))
	if artist == "" {
		http.Error(w, "нужен artist", 400)
		return
	}
	album := strings.TrimSpace(r.URL.Query().Get("album"))
	body := map[string]any{"artist": artist}
	if album != "" {
		body["album"] = album
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	b, err := s.dlPost(ctx, "/torrent/search", body, 95*time.Second)
	if err != nil {
		http.Error(w, err.Error(), 502)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(b) // {candidates:[...], errors:[...]}
}

// POST /api/torrent/download  body: torCand
func (s *Service) hTorrentDownload(w http.ResponseWriter, r *http.Request) {
	var c torCand
	if err := json.NewDecoder(r.Body).Decode(&c); err != nil || c.Tracker == "" {
		http.Error(w, "нужен выбранный релиз", 400)
		return
	}
	if s.sidecarURL() == "" || s.store == nil {
		_, _, reason := s.downloaderState()
		if reason == "" {
			reason = "качалка ещё запускается"
		}
		http.Error(w, reason, 503)
		return
	}
	label := c.Album
	if label == "" {
		label = c.Title
	}
	idx := s.tor().add(c.Tracker, label)
	tj := s.jobs.beginAmbient("torrent", "Качаю альбом: "+label)
	_ = s.db.AddServerLog("info", c.Tracker, label, "качаю альбом с торрента", 0)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Minute)
		defer cancel()
		if err := ensureQBittorrent(); err != nil {
			s.tor().set(idx, "fail", err.Error())
			s.jobs.finishAmbient(tj, err.Error())
			_ = s.db.AddServerLog("error", c.Tracker, label, err.Error(), 0)
			return
		}
		b, err := s.dlPost(ctx, "/torrent/download", map[string]any{
			"tracker": c.Tracker, "forum_url": c.ForumURL, "dl_ref": c.DLRef, "want_title": c.Title,
		}, 40*time.Minute)
		if err != nil {
			s.tor().set(idx, "fail", err.Error())
			s.jobs.finishAmbient(tj, err.Error())
			_ = s.db.AddServerLog("error", c.Tracker, label, "торрент: "+err.Error(), 0)
			return
		}
		var res struct {
			Found  bool   `json:"found"`
			Error  string `json:"error"`
			Tracks []struct {
				FilePath    string `json:"file_path"`
				Artist      string `json:"artist"`
				Title       string `json:"title"`
				Album       string `json:"album"`
				DurationSec int    `json:"duration_sec"`
				BitrateKbps int    `json:"bitrate_kbps"`
				SizeBytes   int64  `json:"size_bytes"`
			} `json:"tracks"`
		}
		_ = json.Unmarshal(b, &res)
		if !res.Found || len(res.Tracks) == 0 {
			note := res.Error
			if note == "" {
				note = "альбом не скачался"
			}
			s.tor().set(idx, "fail", note)
			s.jobs.finishAmbient(tj, note)
			_ = s.db.AddServerLog("error", c.Tracker, label, note, 0)
			return
		}
		added, skipped := s.addAlbumTracks(ctx, res.Tracks, c.Tracker)
		note := fmt.Sprintf("добавлено %d, уже было %d", added, skipped)
		s.tor().set(idx, "done", note)
		s.jobs.finishAmbient(tj, note)
		_ = s.db.AddServerLog("added", c.Tracker, label, fmt.Sprintf("альбом: +%d трек.", added), 0)
	}()
	writeJSON(w, map[string]any{"queued": true})
}

func (s *Service) hTorrentLog(w http.ResponseWriter, r *http.Request) {
	_, permanent, reason := s.downloaderState()
	writeJSON(w, map[string]any{
		"ready":       s.sidecarURL() != "" && s.store != nil,
		"available":   s.dl != nil,
		"permanent":   permanent,
		"reason":      reason,
		"qbittorrent": qBittorrentReachable(), // предупредить заранее (пункт 9), не только после неудачной попытки
		"items":       s.tor().snapshot(),
	})
}

// addAlbumTracks — вписать скачанные mp3 альбома в каталог (пропуская уже
// имеющиеся по normalized_key) и посчитать отпечаток фоном.
func (s *Service) addAlbumTracks(ctx context.Context, tracks []struct {
	FilePath    string `json:"file_path"`
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	DurationSec int    `json:"duration_sec"`
	BitrateKbps int    `json:"bitrate_kbps"`
	SizeBytes   int64  `json:"size_bytes"`
}, tracker string) (added, skipped int) {
	svc := s.acquireService() // для AnalyzeAndStore (тот же Finder/движок)
	for _, t := range tracks {
		if t.Artist == "" || t.Title == "" || t.FilePath == "" {
			continue
		}
		// правило: без рекламных хвостов качалок в метаданных
		t.Artist, t.Title, t.Album = quality.CleanTags(t.Artist, t.Title, t.Album)
		key := quality.NormalizedKey(t.Artist, t.Title)
		if ex, err := s.store.TrackByKey(ctx, key); err == nil && ex != nil {
			skipped++
			continue
		}
		id := "t_" + randHex()
		if err := s.store.InsertTrackWithFile(ctx,
			db.NewTrack{
				ID: id, Artist: t.Artist, Title: t.Title, Album: t.Album,
				DurationSec: t.DurationSec, ReleaseKind: quality.ReleaseKind(t.Title, t.Album),
				IsAltVersion: quality.IsAltVersion(t.Title), NormalizedKey: key,
			},
			db.NewTrackFile{
				ID: "f_" + randHex(), NormalizedKey: key, FilePath: t.FilePath,
				MimeType: quality.MimeFromExt(t.FilePath), BitrateKbps: t.BitrateKbps,
				SizeBytes: t.SizeBytes, DurationSec: t.DurationSec,
				Source: tracker + "_album", QualityTier: "unknown",
			},
		); err != nil {
			continue
		}
		added++
		if svc != nil {
			tid := id
			go func() {
				bg, c := context.WithTimeout(context.Background(), 6*time.Minute)
				defer c()
				_ = svc.AnalyzeAndStore(bg, tid)
			}()
		}
	}
	return added, skipped
}
