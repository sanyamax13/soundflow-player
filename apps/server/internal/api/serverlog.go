package api

import (
	"context"
	"log"
	"net/http"
	"strconv"
	"sync/atomic"

	"soundflow/server/internal/db"
)

// acquireInFlight — сколько скачиваний трека идёт прямо сейчас (для строки
// «сейчас качается» на экране «Сервер», пункт 10). Бампится в acquireTrack и
// в фоновом перекачивании (deleteAndReacquire).
var acquireInFlight atomic.Int64

// logServer — строка в ленту «что делал сервер» (server_log). Лента
// вспомогательная: сбой записи печатаем в консоль и живём дальше, основное
// действие из-за неё не роняем.
func (s *Server) logServer(ctx context.Context, kind, artist, title, detail string, bytes int64) {
	if s.DB == nil {
		return
	}
	if err := s.DB.AddServerLog(ctx, kind, artist, title, detail, bytes); err != nil {
		log.Printf("server_log (%s): %v", kind, err)
	}
}

// busyNow — что сервер делает прямо сейчас (для экрана «Сервер»). Человеческие
// строки, пусто — сервер свободен.
func busyNow() []string {
	var out []string
	if n := acquireInFlight.Load(); n > 0 {
		if n == 1 {
			out = append(out, "качаю трек")
		} else {
			out = append(out, "качаю треки: "+strconv.FormatInt(n, 10))
		}
	}
	if importRunning.Load() {
		out = append(out, "переношу старую библиотеку")
	}
	if backfillCoversRunning.Load() {
		out = append(out, "ищу обложки")
	}
	if reanalyzeRunning.Load() {
		out = append(out, "считаю звуковые отпечатки")
	}
	return out
}

// GET /v1/admin/log?limit= — лента «что делал сервер», новые сверху.
func (s *Server) adminLog(w http.ResponseWriter, r *http.Request) {
	limit := 100
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 500 {
		limit = v
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	rows, err := s.DB.RecentServerLog(r.Context(), limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if rows == nil {
		rows = []db.ServerLogRow{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"log": rows})
}
