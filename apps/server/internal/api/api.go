package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"soundflow/server/internal/acquire"
	"soundflow/server/internal/db"
	"soundflow/server/internal/deezer"
	"soundflow/server/internal/music"
	"soundflow/server/internal/pathmap"
)

type Server struct {
	DB        Store
	Music     *music.Service
	Acquire   *acquire.Service
	PathMap   pathmap.Mapper
	StartedAt time.Time

	// GeneratedCoversDir — папка со сгенерированными обложками (этап 28,
	// 05.09.2026), отдаётся статикой. Пусто — ручка выключена (404 всем).
	GeneratedCoversDir string

	// EraseGate — необязательный шлюз стирания файлов, убранных на телефоне.
	// Программа на компьютере ставит его, чтобы такие файлы не стирались сами, а
	// ждали подтверждения Alex в окне (TG 19943/19948, 19.09.2026). Пусто — файл
	// стирается сразу при приёме события, как раньше.
	EraseGate EraseGate

	// dlTracker — прогресс докачки музыки на телефоны прямо сейчас (в памяти,
	// не в БД). Ленивая инициализация через dl().
	dlOnce    sync.Once
	dlTracker *downloadTracker
}

// EraseGate принимает песню, файл которой надо стереть, но не сразу: ждёт
// подтверждения человека. Метка «больше не качать» к этому моменту уже стоит.
type EraseGate interface {
	HoldErase(ctx context.Context, h HeldErase) error
}

// HeldErase — что шлюз запоминает про песню, убранную на телефоне.
type HeldErase struct {
	TrackID string
	Artist  string
	Title   string
	Path    string // канонический путь файла, как в БД
	Reason  string
	Bytes   int64
}

func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	// Входа нет — плеер личный, сервер в домашней сети. Все ручки открыты.
	r.Route("/v1", func(r chi.Router) {
		// Быстрые ручки — жёсткий таймаут.
		r.Group(func(r chi.Router) {
			r.Use(middleware.Timeout(15 * time.Second))
			r.Get("/health", s.health)
			r.Get("/tracks", s.tracks)
			r.Get("/search", s.search)
			r.Post("/library/next-batch", s.libraryNextBatch)
			r.Get("/trash", s.trashList)
			r.Post("/trash/restore", s.trashRestore)
			r.Post("/trash/purge", s.trashPurge)
			r.Get("/cover/{id}", s.cover)
			r.Get("/generated-covers/{file}", s.generatedCover)
			r.Get("/waveform/{id}", s.waveform)
			r.Post("/stream/order", s.streamOrder)
			r.Post("/sync/events", s.syncEvents)
			r.Post("/sync/progress", s.syncProgress)
			r.Get("/sync/report", s.syncReport)
			r.Get("/device/plan", s.devicePlan)
			r.Post("/device/plan/ack", s.devicePlanAck)
			r.Post("/client-crash", s.clientCrash)
			r.Route("/admin", func(r chi.Router) {
				r.Get("/status", s.adminStatus)
				r.Get("/devices", s.adminDevices)
				r.Get("/events", s.adminEvents)
				r.Get("/blocklist", s.adminBlocklist)
				r.Post("/blocklist/remove", s.adminBlocklistRemove)
				r.Get("/log", s.adminLog)
				r.Get("/language-scan", s.adminLanguageScan)
				r.Post("/reanalyze", s.adminReanalyze)
				r.Post("/sweep-junk", s.adminSweepJunk)
				r.Post("/backfill-covers", s.adminBackfillCovers)
				r.Post("/import-library", s.adminImportLibrary)
			})
		})
		// Скачивание трека через цепочку источников — минуты.
		r.Group(func(r chi.Router) {
			r.Use(middleware.Timeout(10 * time.Minute))
			r.Post("/tracks/acquire", s.acquireTrack)
		})
		// Отдача файла — потоковая, без таймаута.
		r.Get("/music/{id}/file", s.musicFile)
	})
	return r
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	dbState := "ok"
	if err := s.DB.Ping(r.Context()); err != nil {
		dbState = "down"
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "alive",
		"db":      dbState,
		"service": "soundflow",
	})
}

func (s *Server) tracks(w http.ResponseWriter, r *http.Request) {
	// ?limit= — по умолчанию 500, до 10000 (телефон так тянет характеристики
	// файлов для уже скачанного, см. backfillMeta).
	limit := 500
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 10000 {
		limit = v
	}
	// Есть каталог — отдаём его; пусто — тестовые тоны (для демо до наполнения).
	if s.DB.Ping(r.Context()) == nil {
		if list, err := s.DB.CatalogList(r.Context(), limit); err == nil && len(list) > 0 {
			writeJSON(w, http.StatusOK, map[string]any{"tracks": list})
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"tracks": s.Music.List()})
}

func (s *Server) musicFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	// Настоящий трек из каталога — отдаём файл с диска (канонический путь → реальный).
	if s.DB.Ping(r.Context()) == nil {
		if canonical, ok, err := s.DB.TrackFilePath(r.Context(), id); err == nil && ok {
			http.ServeFile(w, r, s.PathMap.ToLocal(canonical))
			return
		}
	}
	// Иначе — тестовый тон / файл из локальной папки.
	s.Music.ServeFile(w, r, id)
}

// --- Синхронизация телефон → сервер (этап 3) ---

type syncReq struct {
	Device struct {
		ID         string `json:"id"`
		Name       string `json:"name"`
		AppVersion string `json:"app_version"`
		MusicBytes int64  `json:"music_bytes"`
		// Transport — как телефон сейчас в сети: wifi | ethernet | mobile |
		// vpn | "". Телефон постарше поле не шлёт — останется прежнее.
		Transport string `json:"transport"`
	} `json:"device"`
	Events []db.SyncEvent `json:"events"`
}

func (s *Server) syncEvents(w http.ResponseWriter, r *http.Request) {
	var req syncReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "битый json"})
		return
	}
	if req.Device.ID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен device.id"})
		return
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	accepted, err := s.DB.SaveSync(r.Context(), db.Device{
		ID:         req.Device.ID,
		Name:       req.Device.Name,
		AppVersion: req.Device.AppVersion,
		MusicBytes: req.Device.MusicBytes,
		Transport:  req.Device.Transport,
	}, req.Events)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if accepted == nil {
		accepted = []string{}
	}
	s.handleDeleteEvents(r.Context(), req.Events, accepted)
	writeJSON(w, http.StatusOK, map[string]any{
		"accepted":    accepted,
		"server_time": time.Now().UTC().Format(time.RFC3339),
	})
}

// handleDeleteEvents — Alex удалил трек на телефоне ("Моя музыка", или
// кнопкой в плеере с причиной — см. player_view.dart). Обычная причина
// (не нравится/надоела/не музыка/другое/без причины): сервер помечает трек
// blocked в legacy_marks (не попадёт в каталог/повторный импорт/повторное
// скачивание) и стирает файл НАСОВСЕМ (Alex 06.09.2026: без корзины на
// 7 дней) — либо сразу, либо, если задан EraseGate (программа на компьютере),
// после подтверждения в окне (Alex TG 19943/19948, 19.09.2026). Причина
// "плохое качество"/"не та версия" — особый случай, см. deleteAndReacquire:
// они шлюз не проходят, замена ищется сама.
// Обрабатываем только реально новые события (accepted), чтобы не дёргать
// файл при каждом повторном синке.
func (s *Server) handleDeleteEvents(ctx context.Context, events []db.SyncEvent, accepted []string) {
	acc := make(map[string]bool, len(accepted))
	for _, id := range accepted {
		acc[id] = true
	}
	for _, e := range events {
		if e.Kind != "delete" || e.TrackID == "" || !acc[e.UUID] {
			continue
		}
		normKey, canonical, ok, err := s.DB.TrackForDeletion(ctx, e.TrackID)
		if err != nil {
			log.Printf("delete-event %s: поиск трека: %v", e.TrackID, err)
			continue
		}
		if !ok {
			continue // трек не наш (тестовый тон и т.п.) — нечего чистить
		}
		local := s.PathMap.ToLocal(canonical)
		reason := deleteReason(e.Payload)

		if reason == "bad_quality" || reason == "wrong_version" {
			s.deleteAndReacquire(ctx, e.TrackID, local, reason)
			continue
		}

		artist, title, _, _ := s.DB.TrackArtistTitle(ctx, e.TrackID)
		var size int64
		fi, statErr := os.Stat(local)
		if statErr == nil {
			size = fi.Size()
		}
		if err := s.DB.UpsertLegacyMark(ctx, db.LegacyMark{Key: normKey, Kind: "blocked", At: time.Now()}); err != nil {
			log.Printf("delete-event %s: пометить blocked: %v", e.TrackID, err)
		}
		// Есть шлюз и файл ещё лежит — не стираем, а ставим в ожидание
		// подтверждения. Не смогли поставить — файл всё равно не трогаем
		// (безопаснее оставить, чем стереть без ведома Alex).
		if s.EraseGate != nil && statErr == nil {
			if err := s.EraseGate.HoldErase(ctx, HeldErase{
				TrackID: e.TrackID, Artist: artist, Title: title,
				Path: canonical, Reason: reason, Bytes: size,
			}); err != nil {
				log.Printf("delete-event %s: поставить на подтверждение: %v", e.TrackID, err)
				s.logServer(ctx, db.LogError, artist, title, "не смог поставить на подтверждение стирания", 0)
			} else {
				s.logServer(ctx, db.LogInfo, artist, title, "убран на телефоне — файл ждёт подтверждения на компьютере", size)
			}
			continue
		}
		if err := pathmap.DeleteForever(local); err != nil {
			log.Printf("delete-event %s: стереть файл (%s): %v", e.TrackID, local, err)
			s.logServer(ctx, db.LogError, artist, title, "не смог стереть файл при удалении", 0)
		} else {
			s.logServer(ctx, db.LogRemoved, artist, title, "убран из плеера", size)
			if reason != "" {
				log.Printf("delete-event %s: стёрт насовсем (%s), причина: %s", e.TrackID, local, reason)
			} else {
				log.Printf("delete-event %s: стёрт насовсем (%s)", e.TrackID, local)
			}
		}
	}
}

// deleteAndReacquire — удаление с причиной "плохое качество"/"не та версия"
// (05.09.2026, просьба Alex, явно подтверждено голосом "да, годится" на
// прямой вопрос). Отличие от обычного удаления: НЕ ставит blocked (иначе
// acquire откажет — "в старом плеере удалён") и стирает саму строку трека
// из каталога (db.DeleteTrack), а не просто прячет — иначе acquire отдал бы
// ту же запись из каталога вместо честного нового поиска (шаг 3 в
// acquire.Acquire ищет по normalized_key). Файл стирается насовсем
// (06.09.2026: без _trash). Замена ищется фоном — телефон не ждёт; не
// нашлась — трек просто останется без замены, ничего не падает.
// "не та версия": перед перекачкой сверяем длительность студийной версии с
// Deezer (пункт 5) и просим acquire отбраковать кавер/ремикс по тегам файла;
// нет чистой версии у Deezer или перекачка не прошла — «нормальной версии не
// нашлось» в ленту, трек остаётся убранным.
func (s *Server) deleteAndReacquire(ctx context.Context, trackID, local, reason string) {
	artist, title, ok, err := s.DB.TrackArtistTitle(ctx, trackID)
	if err != nil || !ok {
		log.Printf("delete-event %s: не нашёл артиста/название для переудаления: %v", trackID, err)
		return
	}
	var size int64
	if fi, statErr := os.Stat(local); statErr == nil {
		size = fi.Size()
	}
	if err := s.DB.DeleteTrack(ctx, trackID); err != nil {
		log.Printf("delete-event %s: стереть строку трека: %v", trackID, err)
		return
	}
	if err := pathmap.DeleteForever(local); err != nil {
		log.Printf("delete-event %s: стереть файл (%s): %v", trackID, local, err)
	}
	s.logServer(ctx, db.LogRemoved, artist, title, "плохая версия — ищу замену", size)
	log.Printf("delete-event %s: причина %q — ищу замену получше (%s — %s)", trackID, reason, artist, title)
	if s.Acquire == nil {
		return
	}
	go func() {
		acquireInFlight.Add(1)
		defer acquireInFlight.Add(-1)
		bg, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel()

		acqReq := acquire.Request{Artist: artist, Title: title}
		if reason == "wrong_version" {
			// Пункт 5: сверяемся с надёжным источником (Deezer — MusicBrainz
			// заблокирован). Берём длительность студийной версии как эталон
			// и просим acquire отбраковать кавер/ремикс по тегам файла.
			acqReq.RejectAltVersions = true
			dctx, dcancel := context.WithTimeout(bg, 20*time.Second)
			canon, derr := deezer.CanonicalTrack(dctx, artist, title)
			dcancel()
			switch {
			case derr == nil && canon.Found && canon.DurationSec > 0:
				acqReq.ExpectedDurationSec = canon.DurationSec
				log.Printf("переудаление %s — %s: эталон Deezer — %d с (%s)", artist, title, canon.DurationSec, canon.Album)
			case derr == nil && !canon.Found:
				log.Printf("переудаление %s — %s: у Deezer нет студийной версии", artist, title)
				s.logServer(context.Background(), db.LogNotFound, artist, title, "нормальной версии не существует", 0)
				return
			}
		}

		res, err := s.Acquire.Acquire(bg, acqReq)
		if err != nil {
			detail := "замену получше не нашёл"
			if reason == "wrong_version" {
				detail = "нормальной версии не нашлось"
			}
			log.Printf("переудаление %s — %s: не нашёл замену: %v", artist, title, err)
			s.logServer(context.Background(), db.LogNotFound, artist, title, detail, 0)
			return
		}
		s.logServer(context.Background(), db.LogReplaced, artist, title, "заменил на версию получше", 0)
		log.Printf("переудаление %s — %s: нашлась замена, новый трек %s", artist, title, res.TrackID)
		if res.Created {
			bg2, cancel2 := context.WithTimeout(context.Background(), 6*time.Minute)
			defer cancel2()
			if e := s.Acquire.AnalyzeAndStore(bg2, res.TrackID); e != nil {
				log.Printf("анализ звука %s: %v", res.TrackID, e)
			}
		}
	}()
}

// deleteReason — причина удаления из payload события (см. PlayerView на
// телефоне, 05.09.2026: Alex попросил спрашивать, почему убирает песню, —
// "не нравится"/"плохое качество"/"не музыка" и т.п.). Пусто — телефон
// постарше, не присылал причину, или причина не выбрана.
func deleteReason(payload json.RawMessage) string {
	if len(payload) == 0 {
		return ""
	}
	var v struct {
		Reason string `json:"reason"`
	}
	if err := json.Unmarshal(payload, &v); err != nil {
		return ""
	}
	return v.Reason
}

func (s *Server) syncReport(w http.ResponseWriter, r *http.Request) {
	dev := r.URL.Query().Get("device")
	if dev == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен параметр device"})
		return
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	last, total, err := s.DB.SyncReport(r.Context(), dev)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	out := map[string]any{"total_events": total}
	if last != nil {
		out["last_sync_at"] = last.UTC().Format(time.RFC3339)
	}
	writeJSON(w, http.StatusOK, out)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
