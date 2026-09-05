package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/go-chi/chi/v5"

	"soundflow/server/internal/acquire"
	"soundflow/server/internal/coverart"
	"soundflow/server/internal/deezer"
	"soundflow/server/internal/importer"
	"soundflow/server/internal/itunes"
	"soundflow/server/internal/pathmap"
)

// GET /v1/search?q= — поиск по уже скачанному каталогу.
func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	limit := 50
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 200 {
		limit = v
	}
	list, err := s.DB.CatalogSearch(r.Context(), q, limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"tracks": list})
}

type acquireReq struct {
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	DurationSec int    `json:"duration_sec"`
}

// POST /v1/tracks/acquire — найти и скачать трек на fg, положить в каталог.
func (s *Server) acquireTrack(w http.ResponseWriter, r *http.Request) {
	var req acquireReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "битый json"})
		return
	}
	if req.Artist == "" || req.Title == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужны artist и title"})
		return
	}
	if s.Acquire == nil || s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "сервер не готов качать (нет базы или сайдкара)"})
		return
	}

	res, err := s.Acquire.Acquire(r.Context(), acquire.Request{
		Artist:              req.Artist,
		Title:               req.Title,
		ExpectedDurationSec: req.DurationSec,
	})
	switch {
	case err == nil:
		if res.Created {
			// «Звуковой отпечаток» считаем фоном — не держим ответ телефону
			// лишние секунды. Догон пропущенного — /v1/admin/reanalyze.
			go func(id string) {
				bg, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
				defer cancel()
				if e := s.Acquire.AnalyzeAndStore(bg, id); e != nil {
					log.Printf("анализ звука %s: %v", id, e)
				}
			}(res.TrackID)
		}
		writeJSON(w, http.StatusOK, res)
	case errors.Is(err, acquire.ErrRejected):
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "отклонено", "reason": res.Reason})
	case errors.Is(err, acquire.ErrNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "не нашлось ни в одном источнике"})
	case errors.Is(err, acquire.ErrLowQuality):
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "плохое качество", "reason": res.Reason})
	default:
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
	}
}

// GET /v1/trash — список убранных (удалено с телефона или зачищено как
// мусор) — можно вернуть.
func (s *Server) trashList(w http.ResponseWriter, r *http.Request) {
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	list, err := s.DB.TrashedTracks(r.Context())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"tracks": list})
}

type trashRestoreReq struct {
	TrackID string `json:"track_id"`
}

// POST /v1/trash/restore — вернуть трек: файл обратно из _trash, метку
// blocked снять — трек снова виден в каталоге и его можно скачать.
func (s *Server) trashRestore(w http.ResponseWriter, r *http.Request) {
	var req trashRestoreReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.TrackID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен track_id"})
		return
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	normKey, canonical, ok, err := s.DB.TrackForDeletion(r.Context(), req.TrackID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "трек не найден"})
		return
	}
	if err := pathmap.RestoreFromTrash(s.PathMap, s.PathMap.ToLocal(canonical)); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if err := s.DB.DeleteLegacyMark(r.Context(), normKey); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"restored": true})
}

// GET /v1/cover/{id} — обложка трека. Сперва пробуем прямо из файла (кто
// рипал альбом, обычно её туда и зашивал) — быстро, без сети. Не нашлось —
// смотрим, не нашёл ли её догон по Яндексу (см. adminBackfillCovers) и
// перенаправляем туда. Ни того ни другого — 404, телефон это умеет
// проглатывать (серый плейсхолдер), ничего не ломает.
// Добавлено 05.09.2026: Alex спросил, почему у перенесённой старой
// библиотеки (этап 12) нет обложек — при переносе (importer.Scan) их никто
// не искал, cover_url заполняется только для треков через acquire.
func (s *Server) cover(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if s.DB.Ping(r.Context()) != nil {
		http.Error(w, "база недоступна", http.StatusServiceUnavailable)
		return
	}
	canonical, ok, err := s.DB.TrackFilePath(r.Context(), id)
	if err != nil || !ok {
		http.NotFound(w, r)
		return
	}
	if data, mime, ok := coverart.Embedded(s.PathMap.ToLocal(canonical)); ok {
		w.Header().Set("Content-Type", mime)
		w.Header().Set("Cache-Control", "public, max-age=604800") // неделя — обложка файла не меняется
		_, _ = w.Write(data)
		return
	}
	if url, found, err := s.DB.TrackCoverURL(r.Context(), id); err == nil && found && strings.HasPrefix(url, "http") {
		http.Redirect(w, r, url, http.StatusFound)
		return
	}
	http.NotFound(w, r)
}

type nextBatchReq struct {
	ExcludeIDs  []string `json:"exclude_ids"`
	BudgetBytes int64    `json:"budget_bytes"`
}

// POST /v1/library/next-batch — «докачать ещё»: телефон шлёт id того, что уже
// скачано, и бюджет в байтах; сервер отдаёт следующую порцию (избранное
// вперёд), пока не наберётся бюджет.
func (s *Server) libraryNextBatch(w http.ResponseWriter, r *http.Request) {
	var req nextBatchReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "битый json"})
		return
	}
	if req.BudgetBytes <= 0 {
		req.BudgetBytes = 20 << 30 // 20 ГБ по умолчанию
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	list, total, err := s.DB.NextLibraryBatch(r.Context(), req.ExcludeIDs, req.BudgetBytes)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"tracks": list, "total_bytes": total})
}

type streamOrderReq struct {
	SeedID       string   `json:"seed_id"`
	CandidateIDs []string `json:"candidate_ids"`
}

// POST /v1/stream/order — упорядочить очередь Потока по близости звучания к
// seed. Телефон шлёт id всех скачанных треков, получает их же в новом порядке.
func (s *Server) streamOrder(w http.ResponseWriter, r *http.Request) {
	var req streamOrderReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "битый json"})
		return
	}
	if req.SeedID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен seed_id"})
		return
	}
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	ordered, err := s.DB.OrderBySimilarity(r.Context(), req.SeedID, req.CandidateIDs)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"track_ids": ordered})
}

// importRunning — не даём двум обходам библиотеки идти параллельно (файлов
// много, смысла нет, а гонка на INSERT/UPDATE в базе не нужна).
var importRunning atomic.Bool

// POST /v1/admin/import-library — разово занести уже скачанную старым
// приложением музыку (D:\SoundFlow\cache, D:\SoundFlow\music) в новый
// каталог. Файлы читаем на месте, никуда не качаем и не двигаем. Долго
// (тысячи файлов) — работает фоном, прогресс смотреть в логе сервера или
// по счётчику каталога в /v1/admin/status.
func (s *Server) adminImportLibrary(w http.ResponseWriter, r *http.Request) {
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	roots := s.PathMap.LocalRoots()
	if len(roots) == 0 {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "не настроены пути библиотеки (SIDECAR_LOCAL_*_DIR)"})
		return
	}
	if !importRunning.CompareAndSwap(false, true) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "перенос уже идёт"})
		return
	}
	go func() {
		defer importRunning.Store(false)
		start := time.Now()
		res, err := importer.Scan(context.Background(), s.DB, s.PathMap, roots)
		if err != nil {
			log.Printf("import-library: остановлен ошибкой: %v (успело: %+v)", err, res)
			return
		}
		log.Printf("import-library: готово за %s — %+v", time.Since(start).Round(time.Second), res)
	}()
	writeJSON(w, http.StatusAccepted, map[string]any{"started": true, "roots": roots})
}

// reanalyzeRunning — не даём двум догонам звукового отпечатка идти
// параллельно (сайдкар и так считает по одному треку за раз).
var reanalyzeRunning atomic.Bool

// POST /v1/admin/sweep-junk — прогнать уже существующий каталог через
// текущие правила отсева мусора (Screen) ещё раз — например, после того как
// список мусорных слов расширили. Не стирает файлы насовсем — переносит в
// _trash и метит blocked (как удаление с телефона). Быстро (только Go-регексы
// по уже загруженным строкам, без похода в сайдкар) — работает синхронно,
// сразу возвращает список того, что убрал.
func (s *Server) adminSweepJunk(w http.ResponseWriter, r *http.Request) {
	if s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "база недоступна"})
		return
	}
	res, removed, err := importer.Sweep(r.Context(), s.DB, s.PathMap)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	list := make([]map[string]string, 0, len(removed))
	for _, t := range removed {
		list = append(list, map[string]string{"artist": t.Artist, "title": t.Title})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"checked": res.Checked, "removed": res.Removed, "errors": res.Errors, "removed_list": list,
	})
}

// backfillCoversRunning — не даём двум догонам обложек идти параллельно
// (сайдкар и так спрашивает Яндекс по одному запросу за раз).
var backfillCoversRunning atomic.Bool

// POST /v1/admin/backfill-covers — досчитать обложки трекам без своей в
// файле: спросить Яндекс.Музыку (тот же сайдкар, что и acquire), не нашлось —
// iTunes Search, всё ещё не нашлось — Deezer Search (оба открытые API без
// ключа). Добавлено 05.09.2026 по просьбе Alex — сперва "давай найдём
// обложку у тех, у кого её нет" (после того как выяснилось, что 57% старой
// библиотеки несёт обложку прямо в файле), затем "для тех, у кого не
// нашлось, поищи в интернете" (iTunes, почти ничего не добавил — 7 из
// 1673) и следом "надо сделать веб-ресерч чтобы найти все обложки" (Deezer;
// MusicBrainz для сравнения оказался недоступен — заблокирован — и с brain,
// и с fg, проверено напрямую). Берёт только треки, которые не смотрели
// вообще ни разу ("" — см. db.TracksMissingCoverURL) — трек, помеченный
// "none", сюда больше не попадает: раньше выборка пускала "none" на
// пересмотр при каждом новом источнике, и догон крутился по кругу
// бесконечно, не заканчиваясь (баг найден и исправлен 05.09.2026). Новый
// источник обложек — сбросить нужные "none" обратно на "" вручную, разовым
// UPDATE (как сделано для Deezer). Файл со своей обложкой не трогаем
// (ручка /v1/cover уже отдаёт её из файла) — только помечаем "embedded",
// чтобы не проверять по кругу. Сеть — не быстро; работает фоном, как
// /v1/admin/reanalyze.
func (s *Server) adminBackfillCovers(w http.ResponseWriter, r *http.Request) {
	if s.Acquire == nil || s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "сервер не готов"})
		return
	}
	if !backfillCoversRunning.CompareAndSwap(false, true) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "догон обложек уже идёт"})
		return
	}
	go func() {
		defer backfillCoversRunning.Store(false)
		start := time.Now()
		var checked, embedded, found, none int
		for {
			batch, err := s.DB.TracksMissingCoverURL(context.Background(), 200)
			if err != nil {
				log.Printf("backfill-covers: список треков: %v", err)
				return
			}
			if len(batch) == 0 {
				break
			}
			for _, c := range batch {
				checked++
				if _, _, ok := coverart.Embedded(s.PathMap.ToLocal(c.FilePath)); ok {
					_ = s.DB.SetCoverURL(context.Background(), c.ID, "embedded")
					embedded++
					continue
				}
				bg, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				url, _ := s.Acquire.Finder.YandexTrackCover(bg, c.Artist, c.Title)
				cancel()
				if url == "" { // Яндекс не нашёл — пробуем iTunes
					bg, cancel := context.WithTimeout(context.Background(), 30*time.Second)
					url, _ = itunes.Cover(bg, c.Artist, c.Title)
					cancel()
				}
				if url == "" { // iTunes тоже не нашёл — пробуем Deezer
					bg, cancel := context.WithTimeout(context.Background(), 30*time.Second)
					url, _ = deezer.Cover(bg, c.Artist, c.Title)
					cancel()
				}
				if url == "" {
					_ = s.DB.SetCoverURL(context.Background(), c.ID, "none")
					none++
					continue
				}
				_ = s.DB.SetCoverURL(context.Background(), c.ID, url)
				found++
			}
			log.Printf("backfill-covers: пока %d проверено (своя в файле: %d, нашли внешнюю: %d, не нашли: %d)",
				checked, embedded, found, none)
		}
		log.Printf("backfill-covers: готово за %s — проверено %d, своя в файле %d, нашли внешнюю %d, не нашли %d",
			time.Since(start).Round(time.Second), checked, embedded, found, none)
	}()
	writeJSON(w, http.StatusAccepted, map[string]any{"started": true})
}

// POST /v1/admin/reanalyze — досчитать «звуковой отпечаток» трекам, у которых
// его нет (после переноса каталога, сбоев сайдкара). Раньше брал только одну
// пачку до 500 штук за вызов; после переноса старой библиотеки (этап 12)
// без отпечатка осталось ~8776 треков — по ~9с на трек это почти сутки,
// дёргать вручную раз в 500 неудобно. Теперь один вызов сам крутит пачки,
// пока без отпечатка не останется никого; работает фоном, прогресс — по
// логу сервера или количеству треков с отпечатком в /v1/admin/status.
func (s *Server) adminReanalyze(w http.ResponseWriter, r *http.Request) {
	if s.Acquire == nil || s.DB.Ping(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "сервер не готов"})
		return
	}
	if !reanalyzeRunning.CompareAndSwap(false, true) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "догон уже идёт"})
		return
	}
	go func() {
		defer reanalyzeRunning.Store(false)
		start := time.Now()
		total := 0
		for {
			ids, err := s.DB.TrackIDsWithoutFeatures(context.Background(), 500)
			if err != nil {
				log.Printf("reanalyze: список треков: %v", err)
				return
			}
			if len(ids) == 0 {
				break
			}
			for _, id := range ids {
				bg, cancel := context.WithTimeout(context.Background(), 6*time.Minute)
				if e := s.Acquire.AnalyzeAndStore(bg, id); e != nil {
					log.Printf("reanalyze %s: %v", id, e)
				}
				cancel()
				total++
			}
		}
		log.Printf("reanalyze: готово за %s — обработано %d трек(ов)", time.Since(start).Round(time.Second), total)
	}()
	writeJSON(w, http.StatusAccepted, map[string]any{"started": true})
}
