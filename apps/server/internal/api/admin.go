package api

import (
	"encoding/json"
	"net/http"
	"runtime"
	"strconv"
	"time"

	"soundflow/server/internal/diskspace"
	"soundflow/server/internal/quality"
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
		"busy":         busyNow(),
	}
	var musicBytes int64
	if dbState == "ok" {
		if st, err := s.DB.AdminStatus(r.Context()); err == nil {
			musicBytes = st.MusicBytes
			out["catalog"] = map[string]int64{
				"tracks":            st.Tracks,
				"track_files":       st.TrackFiles,
				"hidden_by_quality": st.HiddenByQ,
			}
			out["events"] = map[string]any{"total": st.EventsTotal, "by_kind": st.EventsByKind}
			out["devices"] = st.Devices
			out["migrations"] = st.Migrations
			out["legacy"] = map[string]int64{"favorites": st.LegacyFavs, "blocked": st.LegacyBlocked}
		} else {
			out["db"] = "error"
			out["db_error"] = err.Error()
		}
		if rep, err := s.DB.ServerReportSince(r.Context(), 30); err == nil {
			out["report"] = rep
		}
	}
	// Место на диске под музыку — по первому корню библиотеки.
	if roots := s.PathMap.LocalRoots(); len(roots) > 0 {
		if free, total, err := diskspace.Free(roots[0]); err == nil {
			out["disk"] = map[string]int64{
				"free_bytes":  free,
				"total_bytes": total,
				"music_bytes": musicBytes,
			}
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

// GET /v1/admin/blocklist — список «больше не качать» для экрана «Сервер»
// (Alex 06.09.2026, разбор плеера п.10/12). Сюда попадают и удалённые в
// плеере треки, и старый чёрный список. По этим ключам сервер не отдаёт
// трек в каталог и не качает заново.
func (s *Server) adminBlocklist(w http.ResponseWriter, r *http.Request) {
	limit := 500
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 5000 {
		limit = v
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	list, err := s.DB.ListBlocked(r.Context(), limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"blocked": list})
}

// GET /v1/admin/language-scan — сухой прогон чистки по языкам (п.7б):
// сколько треков каталога на языке вне белого списка (рус/англ/нем/фр/итал).
// НИЧЕГО НЕ УДАЛЯЕТ — только считает и даёт образец. Настоящая чистка —
// отдельной ручкой с подтверждением числа (ещё не сделана).
func (s *Server) adminLanguageScan(w http.ResponseWriter, r *http.Request) {
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	list, err := s.DB.CatalogList(r.Context(), 20000)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	byLang := map[string]int{}
	sample := make([]map[string]string, 0, 30)
	total := 0
	for _, t := range list {
		if quality.LanguageAllowed(t.Artist, t.Title) {
			continue
		}
		total++
		lang := quality.GuessLanguage(t.Artist, t.Title)
		byLang[lang]++
		if len(sample) < 30 {
			sample = append(sample, map[string]string{"artist": t.Artist, "title": t.Title, "lang": lang})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"scanned": len(list), "would_remove": total, "by_language": byLang, "sample": sample,
	})
}

type blocklistRemoveReq struct {
	Key string `json:"key"`
}

// POST /v1/admin/blocklist/remove — убрать один ключ из списка «больше не
// качать» (случайно попал / передумал). После этого трек снова можно
// скачать. Файл при этом не возвращается — если он был стёрт, качается
// заново из источника.
func (s *Server) adminBlocklistRemove(w http.ResponseWriter, r *http.Request) {
	var req blocklistRemoveReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Key == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен key"})
		return
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	if err := s.DB.DeleteLegacyMark(r.Context(), req.Key); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"removed": true})
}
