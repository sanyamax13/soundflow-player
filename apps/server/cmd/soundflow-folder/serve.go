package main

import (
	"encoding/json"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"

	"github.com/dhowden/tag"
)

// Server раздаёт песни из папки по тому же API, что и настоящий SoundFlow —
// приложению всё равно, к кому подключаться.
type Server struct {
	mu    sync.RWMutex
	items []Item
	byID  map[string]Item
}

func NewServer() *Server { return &Server{byID: map[string]Item{}} }

func (s *Server) SetItems(items []Item) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.items = items
	s.byID = make(map[string]Item, len(items))
	for _, it := range items {
		s.byID[it.ID] = it
	}
}

func (s *Server) Count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.items)
}

type trackJSON struct {
	ID          string `json:"id"`
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	DurationSec int    `json:"duration_sec"`
	ReleaseKind string `json:"release_kind"`
	Explicit    bool   `json:"explicit"`
	CoverURL    string `json:"cover_url"`
	Favorite    bool   `json:"favorite"`
	SizeBytes   int64  `json:"size_bytes"`
	BitrateKbps int    `json:"bitrate_kbps"`
	MimeType    string `json:"mime_type"`
}

func (s *Server) toJSON(it Item, host string) trackJSON {
	cover := ""
	if it.HasCover && host != "" {
		cover = "http://" + host + "/v1/cover/" + it.ID
	}
	return trackJSON{
		ID: it.ID, Artist: it.Artist, Title: it.Title, Album: it.Album,
		DurationSec: it.DurationSec, ReleaseKind: "studio", Explicit: false,
		CoverURL: cover, Favorite: false, SizeBytes: it.Size,
		BitrateKbps: it.BitrateKbps, MimeType: it.MimeType,
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"status": "alive", "db": "ok"})
	})

	mux.HandleFunc("/v1/tracks", func(w http.ResponseWriter, r *http.Request) {
		limit := 500
		if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 {
			limit = v
		}
		s.mu.RLock()
		defer s.mu.RUnlock()
		out := make([]trackJSON, 0, len(s.items))
		for i, it := range s.items {
			if i >= limit {
				break
			}
			out = append(out, s.toJSON(it, r.Host))
		}
		writeJSON(w, map[string]any{"tracks": out})
	})

	// «Докачать ещё N байт»: телефон шлёт то, что уже есть, и бюджет.
	mux.HandleFunc("/v1/library/next-batch", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ExcludeIDs  []string `json:"exclude_ids"`
			BudgetBytes int64    `json:"budget_bytes"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		if req.BudgetBytes <= 0 {
			req.BudgetBytes = 1 << 60
		}
		skip := make(map[string]bool, len(req.ExcludeIDs))
		for _, id := range req.ExcludeIDs {
			skip[id] = true
		}
		s.mu.RLock()
		defer s.mu.RUnlock()
		out := make([]trackJSON, 0)
		var total int64
		for _, it := range s.items {
			if skip[it.ID] {
				continue
			}
			if len(out) > 0 && total >= req.BudgetBytes {
				break
			}
			out = append(out, s.toJSON(it, r.Host))
			total += it.Size
		}
		writeJSON(w, map[string]any{"tracks": out, "total_bytes": total})
	})

	mux.HandleFunc("/v1/music/", func(w http.ResponseWriter, r *http.Request) {
		// /v1/music/{id}/file
		id := trimPath(r.URL.Path, "/v1/music/", "/file")
		s.mu.RLock()
		it, ok := s.byID[id]
		s.mu.RUnlock()
		if !ok {
			http.NotFound(w, r)
			return
		}
		http.ServeFile(w, r, it.Path)
	})

	mux.HandleFunc("/v1/cover/", func(w http.ResponseWriter, r *http.Request) {
		id := trimPath(r.URL.Path, "/v1/cover/", "")
		s.mu.RLock()
		it, ok := s.byID[id]
		s.mu.RUnlock()

		// Есть картинка в файле — отдаём её.
		if ok && it.HasCover {
			if f, err := os.Open(it.Path); err == nil {
				defer f.Close()
				if m, err := tag.ReadFrom(f); err == nil && m.Picture() != nil {
					pic := m.Picture()
					if pic.MIMEType != "" {
						w.Header().Set("Content-Type", pic.MIMEType)
					}
					w.Write(pic.Data)
					return
				}
			}
		}

		// Нет — рисуем заглушку (Alex TG 18725), как генерённые обложки сервера.
		seed := id
		if ok {
			seed = it.Artist + "|" + it.Title
		}
		w.Header().Set("Content-Type", "image/png")
		w.Write(generatedCover(seed))
	})

	// Телефон шлёт лайки/удаления/что слушал — тестовому серверу это не нужно,
	// просто принимаем.
	mux.HandleFunc("/v1/sync/events", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Events []json.RawMessage `json:"events"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		writeJSON(w, map[string]any{"accepted": len(req.Events), "server_time": ""})
	})

	// Порядок «Потока» по звуку — без анализа звука, отдаём как прислали.
	mux.HandleFunc("/v1/stream/order", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			CandidateIDs []string `json:"candidate_ids"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		writeJSON(w, map[string]any{"track_ids": req.CandidateIDs, "reordered": false})
	})

	mux.HandleFunc("/v1/admin/status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{
			"db": "ok", "status": "alive", "music_source": "папка тестировщика",
			"catalog": map[string]any{"tracks": s.Count()},
			"events":  map[string]any{"total": 0, "by_kind": map[string]any{}},
			"devices": 0,
		})
	})
	mux.HandleFunc("/v1/admin/devices", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"devices": []any{}})
	})
	mux.HandleFunc("/v1/admin/events", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"events": []any{}})
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"тестовый сервер: этого метода нет"}`, http.StatusNotFound)
	})
	return withCORS(mux)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

func withCORS(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		h.ServeHTTP(w, r)
	})
}

func trimPath(path, prefix, suffix string) string {
	s := path
	if len(s) >= len(prefix) {
		s = s[len(prefix):]
	}
	if suffix != "" && len(s) >= len(suffix) && s[len(s)-len(suffix):] == suffix {
		s = s[:len(s)-len(suffix)]
	}
	return s
}

// LANAddr — первый частный IPv4 этого компьютера (для показа в окне).
func LANAddr() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipnet.IP.To4()
			if ip == nil {
				continue
			}
			if ip[0] == 10 || (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) || (ip[0] == 192 && ip[1] == 168) {
				return ip.String()
			}
		}
	}
	return ""
}
