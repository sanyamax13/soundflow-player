package api

import (
	"net/http"
	"runtime"
	"strconv"
	"time"
)

// Админка (этап 6). PIN нет — плеер личный, сервер в домашней сети.
// Пока каталог пуст, а поиск/скачивание не сделаны — очередь и отчёты
// показывать нечего; здесь состояние сервера, устройства и лента событий.

func (s *Server) adminStatus(w http.ResponseWriter, r *http.Request) {
	dbState := "ok"
	if err := s.DB.Ping(r.Context()); err != nil {
		dbState = "down"
	}
	out := map[string]any{
		"db":           dbState,
		"uptime_sec":   int(time.Since(s.StartedAt).Seconds()),
		"go_version":   runtime.Version(),
		"server_time":  time.Now().UTC().Format(time.RFC3339),
		"music_source": s.Music.SourceLabel(),
	}
	if dbState == "ok" {
		if st, err := s.DB.AdminStatus(r.Context()); err == nil {
			out["catalog"] = map[string]int64{"tracks": st.Tracks, "track_files": st.TrackFiles}
			out["events"] = map[string]any{"total": st.EventsTotal, "by_kind": st.EventsByKind}
			out["devices"] = st.Devices
			out["migrations"] = st.Migrations
			out["legacy"] = map[string]int64{"favorites": st.LegacyFavs, "blocked": st.LegacyBlocked}
		} else {
			out["db"] = "error"
			out["db_error"] = err.Error()
		}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) adminDevices(w http.ResponseWriter, r *http.Request) {
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	list, err := s.DB.ListDevices(r.Context())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": list})
}

func (s *Server) adminEvents(w http.ResponseWriter, r *http.Request) {
	limit := 50
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 500 {
		limit = v
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	list, err := s.DB.RecentEvents(r.Context(), limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": list})
}
