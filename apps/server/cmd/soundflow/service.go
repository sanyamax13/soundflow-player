package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	qrcode "github.com/skip2/go-qrcode"

	"soundflow/server/internal/api"
	"soundflow/server/internal/coverart"
	"soundflow/server/internal/db"
	"soundflow/server/internal/diskspace"
	"soundflow/server/internal/inference"
	"soundflow/server/internal/litestore"
	"soundflow/server/internal/localdb"
	"soundflow/server/internal/pathmap"
)

// Service — состояние приложения: база, модель, фоновые задачи.
type Service struct {
	ctx       context.Context
	dataDir   string
	dbPath    string
	assetsDir string
	db        *localdb.DB
	eng       *inference.Engine // nil, если не нашли onnxruntime.dll/cnn14.onnx
	jobs      *JobRunner
	phoneAddr string
	phoneSrv  *http.Server
	phoneAPI  *api.Server        // тот же /v1-сервер; окну нужен для «качает прямо сейчас»
	dl        *downloaderProc    // дочерний Python «качалка» (Найти трек / торренты)
	store     *litestore.Store   // та же БД для acquire из окна
	covers    *coverKeeper       // сама ищет обложки песням, у которых их нет (coverkeeper.go)
	recon     *reconciler        // сама сверяет каталог с диском: убирает песни без файла (reconcile.go)
	waveMu    sync.Mutex         // «Пересобрать волну» идёт минуту — вторая пересборка одновременно не нужна
	waveStop  context.CancelFunc // останавливает waveDailyLoop (сама собирает волну на сегодня, yandex_wave.go)
	pcMu      sync.Mutex         // кэш «песен компьютера с файлом на диске» для сверки с телефоном (phonecheck.go)
	pcAt      time.Time
	pcSet     map[string]int64
	guardMu   sync.Mutex // одна проверка «сторожа по звуку» за раз (dislikeguard.go)
	guardStop context.CancelFunc
	waveEmbed func(ctx context.Context, it yandexWaveOut) ([]float32, error) // отпечаток кандидата «Волны»; nil — настоящий (в тестах подменяют)
	pm        pathmap.Mapper                                                 // канон→локальный путь для acquire/отпечатка
	acqOnce   sync.Once
	acqT      *acqTracker // последние попытки «Найти трек»
	torOnce   sync.Once
	torT      *torTracker // последние закачки «Торренты — обзор»
	startedAt time.Time
	frontend  embed.FS
	mu        sync.Mutex

	// Честный статус телефонного слушателя (Опус-ревью 14.09.2026, пункт 1):
	// раньше окно всегда показывало «сервер работает», даже если порт был
	// занят другой программой (реальный случай — TorrServer на 8090) и
	// bind тихо падал в фоне. phoneListening/phoneBoundAddr/phoneListenErr
	// отражают, что произошло НА САМОМ ДЕЛЕ.
	phoneListening bool
	phoneBoundAddr string // "" пока не забиндились; напр. "0.0.0.0:8091"
	phoneListenErr string
}

// staticHandler — отдаёт вшитый frontend/ (index.html в корне).
func (s *Service) staticHandler() http.Handler {
	sub, err := fs.Sub(s.frontend, "frontend")
	if err != nil {
		return http.NotFoundHandler()
	}
	return http.FileServer(http.FS(sub))
}

func NewService() (*Service, error) {
	data := dataDir()
	if err := os.MkdirAll(data, 0o755); err != nil {
		return nil, err
	}
	dbPath := env("SOUNDFLOW_DB", filepath.Join(data, "soundflow.db"))
	if _, err := os.Stat(dbPath); err != nil {
		// dev: рядом с репой
		for _, alt := range []string{
			`E:\soundflow-lab\soundflow.db`,
			filepath.Join(".", "soundflow.db"),
		} {
			if _, e := os.Stat(alt); e == nil {
				dbPath = alt
				break
			}
		}
	}
	db, err := localdb.Open(dbPath)
	if err != nil {
		return nil, fmt.Errorf("база %s: %w", dbPath, err)
	}
	// Слой 'recent' протухает по времени (окно 21 день), а не только по
	// событиям — пересчитываем и при старте, чтобы неделю простоя не
	// показывала позапрошлый месяц до первого нового лайка.
	go func() {
		_, _, _ = db.RecomputeTasteClusters("long_term", nil)
		cutoff := time.Now().AddDate(0, 0, -21)
		_, _, _ = db.RecomputeTasteClusters("recent", &cutoff)
	}()

	assets := env("SOUNDFLOW_ASSETS", exeDir())
	var eng *inference.Engine
	if e, err := inference.Open(assets); err == nil {
		eng = e
	} else {
		fmt.Printf("SoundFlow: модель отпечатков не загружена (%v) — окно и каталог работают, пересчёт выключен\n", err)
	}

	s := &Service{
		dataDir: data, dbPath: dbPath, assetsDir: assets,
		db: db, eng: eng, phoneAddr: env("SOUNDFLOW_ADDR", ":8090"),
		startedAt: time.Now(),
	}
	s.jobs = NewJobRunner(s)
	// Alex TG 13.09.2026: не хочет думать про кнопку «Пересчитать похожесть
	// по звуку» — скан и «Найти и скачать» и так считают отпечаток сразу
	// при добавлении трека (jobs.go, acquire.go), эта проверка на старте
	// добирает редкие хвосты (модель не была загружена в момент добавления,
	// разовый сбой распознавания) молча в фоне, без участия Alex.
	if eng != nil {
		go func() {
			if ids, err := db.TrackIDsNeedingAnalysis(0); err == nil && len(ids) > 0 {
				s.jobs.StartReindex()
			}
		}()
	}
	_ = s.db.AddServerLog("info", "", "", "SoundFlow запущен ("+dbPath+"), модель: "+yn(eng != nil), 0)
	fmt.Printf("SoundFlow: база %s, модель %v, телефонный API %s\n", dbPath, eng != nil, s.phoneAddr)
	if s.dl = newDownloaderProc(); s.dl != nil {
		go s.dl.run()
	}
	writeServerLogSafe = func(m string) error { return s.db.AddServerLog("info", "", "", m, 0) }
	go s.startPhoneServer()
	s.covers = newCoverKeeper(s)
	s.covers.Start()
	s.recon = newReconciler(s)
	s.recon.Start()
	waveCtx, waveStop := context.WithCancel(context.Background())
	s.waveStop = waveStop
	go s.waveDailyLoop(waveCtx)
	guardCtx, guardStop := context.WithCancel(context.Background())
	s.guardStop = guardStop
	go s.dislikeGuardLoop(guardCtx)
	return s, nil
}

func yn(b bool) string {
	if b {
		return "есть"
	}
	return "нет"
}

func (s *Service) OnStartup(ctx context.Context) {
	s.ctx = ctx
	fmt.Println("SoundFlow: окно готово")
}

func (s *Service) OnShutdown(ctx context.Context) {
	if s.phoneSrv != nil {
		_ = s.phoneSrv.Close()
	}
	s.dl.shutdown()
	s.covers.Stop()
	s.recon.Stop()
	if s.waveStop != nil {
		s.waveStop()
	}
	if s.guardStop != nil {
		s.guardStop()
	}
	s.jobs.CancelAll()
	if s.eng != nil {
		_ = s.eng.Close()
	}
	_ = s.db.Close()
}

// ---------------- HTTP: фронт зовёт эти ручки ----------------

// APIRouter — обработчик для окна Wails: /api/* и /audio/* (статику окну отдаёт
// сам Wails из вшитого frontend).
func (s *Service) APIRouter() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.Recoverer)
	r.Use(markFromWindow) // только путь окна: ручки «только с этого компьютера» его пускают, см. localOnly
	s.mountAPI(r)
	return r
}

// mountAPI — ручки окна. Используется и в Wails, и в телефонном сервере (чтобы
// окно можно было открыть и обычным браузером для отладки).
func (s *Service) mountAPI(r chi.Router) {
	r.Get("/api/info", s.hInfo)
	r.Get("/api/qr.png", s.hQR)
	r.Get("/api/catalog", s.hCatalog)
	r.Get("/api/catalog/flat", s.hCatalogFlat)
	r.Get("/api/catalog/new-since", s.hCatalogNewSince)
	r.Get("/api/settings/watch-dir", s.hWatchDirGet)
	r.Post("/api/settings/watch-dir", s.hWatchDirSet)
	r.Get("/api/yandex/playlist", s.hYandexPlaylist)
	r.Post("/api/yandex/dislikes/import", s.hYandexDislikesImport)
	r.Get("/api/yandex/wave", s.hYandexWave)
	r.Get("/api/yandex/wave/days", s.hYandexWaveDays)
	r.Post("/api/phone/favorites", s.hPhoneFavoritesReport)
	r.Get("/api/phone/missing-favorites", s.hPhoneFavoritesMissing)
	r.Post("/api/discover/dismiss", localOnly(s.hDiscoverDismiss))
	r.Post("/api/discover/undismiss", localOnly(s.hDiscoverUndismiss))
	r.Get("/api/yandex/preview", localOnly(s.hYandexPreview))
	r.Get("/api/roots", s.hRoots)
	r.Get("/api/search", s.hSearch)
	r.Get("/api/devices", s.hDevices)
	r.Delete("/api/devices/{id}", s.hDeviceDelete)
	r.Get("/api/devices/{id}/sync-preview", s.hSyncPreview)
	r.Post("/api/devices/{id}/sync-plan", s.hSyncPlanCommit)
	r.Post("/api/devices/{id}/track/delete", s.hDevTrackDelete)
	// контекстное меню окна (Alex TG 20039–20045). Команды, что меняют файлы/план или
	// запускают проводник, — только с этого компьютера (см. localOnly).
	r.Get("/api/phone/state", s.hPhoneState)
	// сверка телефона с компьютером (phonecheck.go): телефон присылает точный список, окно показывает числа,
	// «Выровнять» — только с этого компьютера
	r.Post("/api/phone/inventory", s.hPhoneInventory)
	r.Get("/api/phone/check", s.hPhoneCheck)
	r.Post("/api/phone/align", localOnly(s.hPhoneAlign))
	r.Post("/api/phone/plan", localOnly(s.hPhonePlan))
	r.Get("/api/phone/plan", s.hPhonePlanGet)
	r.Delete("/api/phone/plan", localOnly(s.hPhonePlanCancel))
	r.Post("/api/tracks/delete-forever", localOnly(s.hDeleteForever))
	r.Get("/api/catalog/missing", s.hMissing)
	r.Post("/api/catalog/missing/clean", localOnly(s.hMissingClean))
	// возврат песен с телефона на ПК, разово и без кнопок (restore.go): очередь ставим только с этого компьютера,
	// телефон сам забирает список и отдаёт файлы
	r.Post("/api/restore/request", localOnly(s.hRestoreRequest))
	r.Post("/api/restore/cancel", localOnly(s.hRestoreCancel))
	r.Get("/api/restore/status", s.hRestoreStatus)
	r.Get("/api/restore/wanted", s.hRestoreWanted)
	r.Post("/api/restore/missing", s.hRestoreMissing)
	r.Put("/api/restore/upload/{id}", s.hRestoreUpload)
	r.Get("/api/catalog/blocked-files", s.hBlockedFiles)
	r.Post("/api/catalog/blocked-files/erase", localOnly(s.hBlockedFilesErase))
	r.Post("/api/tracks/copies", localOnly(s.hTrackCopies))
	r.Post("/api/reveal", localOnly(s.hReveal))
	r.Post("/api/open-folder", localOnly(s.hOpenFolder))
	r.Get("/api/removals", s.hRemovals)
	r.Post("/api/removals/confirm", s.hRemovalsConfirm)
	r.Get("/api/devices/{id}/suggest", s.hSuggest)
	r.Get("/api/log", s.hLog)
	r.Get("/api/taste", s.hTaste)
	r.Post("/api/taste/rebuild", s.hTasteRebuild)
	r.Get("/api/taste/dislike-guard", s.hGuardStatus)
	r.Post("/api/taste/dislike-guard/check", localOnly(s.hGuardCheck))
	r.Post("/api/taste/cluster", s.hTasteCluster)
	r.Get("/api/taste/centroids-hash", s.hCentroidsHash)
	r.Get("/api/taste/centroids", s.hCentroids)
	r.Post("/api/tracks/vectors", s.hTrackVectors)
	r.Get("/api/jobs", s.hJobs)
	r.Post("/api/scan", s.hScan)
	r.Post("/api/reindex", s.hReindex)
	r.Post("/api/stop", s.hStop)
	r.Post("/api/acquire", s.hAcquire)
	r.Get("/api/acquire/log", s.hAcquireLog)
	r.Post("/api/torrent/search", s.hTorrentSearch)
	r.Post("/api/torrent/download", s.hTorrentDownload)
	r.Get("/api/torrent/log", s.hTorrentLog)
	r.Get("/audio/{id}", s.hAudio)
	r.Get("/api/cover/{id}", s.hCover)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

// currentAddr — реальный адрес, на котором сейчас висит телефонный API (с
// учётом отката порта из пункта 1), в виде "<ip в локальной сети>:порт".
// Общий для hInfo и QR-кода (пункт 6) — один источник правды, а не два места,
// которые могут разойтись.
func (s *Service) currentAddr() (addr string, fellBack bool) {
	s.mu.Lock()
	boundAddr := s.phoneBoundAddr
	s.mu.Unlock()
	addr = localAddr(s.phoneAddr)
	if boundAddr != "" {
		addr = localAddr(boundAddr)
		fellBack = boundAddr != s.phoneAddr
	}
	return addr, fellBack
}

// localURL — адрес самой программы «изнутри» этого компьютера (порт — реально занятый, с учётом отката).
// Окно (WebView2) не умеет играть звук, который программа отдаёт ему изнутри окна: песня не начинается и
// ошибки нет (Alex TG 20095, 20.09.2026). По настоящему адресу — как в браузере — играет.
func (s *Service) localURL() string {
	s.mu.Lock()
	bound := s.phoneBoundAddr
	s.mu.Unlock()
	if bound == "" {
		bound = s.phoneAddr
	}
	port := bound
	if i := strings.LastIndex(bound, ":"); i >= 0 {
		port = bound[i+1:]
	}
	return "http://127.0.0.1:" + port
}

func (s *Service) hInfo(w http.ResponseWriter, r *http.Request) {
	c, _ := s.db.Counts()
	// Alex TG 15.09.2026: «на каком диске 35? синхронизируешь на диск С?» —
	// раньше свободное место всегда мерили от dataDir() (%LocalAppData%,
	// системный C:), даже когда SOUNDFLOW_DB/SOUNDFLOW_AUDIO_ROOT указывают
	// на другой диск (у Alex — E:). Теперь меряем диск, где реально лежит
	// база — s.dbPath, а не фиксированный dataDir.
	dataDrive := filepath.VolumeName(s.dbPath)
	free, _, _ := diskspace.Free(filepath.Dir(s.dbPath))
	s.mu.Lock()
	listening, listenErr := s.phoneListening, s.phoneListenErr
	s.mu.Unlock()
	addr, fellBack := s.currentAddr()
	writeJSON(w, map[string]any{
		"addr":            addr,
		"local_url":       s.localURL(), // окно проигрывает звук по нему, а не через себя (см. frontend _audioBase)
		"running":         listening,    // раньше было true всегда — теперь по факту привязки порта
		"listen_error":    listenErr,
		"addr_fell_back":  fellBack, // порт из настроек был занят, взяли следующий свободный
		"configured_addr": localAddr(s.phoneAddr),
		"has_model":       s.eng != nil,
		"tracks":          c.Tracks,
		"with_vector":     c.WithVector,
		"albums":          c.AlbumsGuess,
		"files":           c.TrackFiles,
		"disk_free":       free,
		"data_drive":      dataDrive,
		"db_path":         s.dbPath,
		"uptime_sec":      int(time.Since(s.startedAt).Seconds()),
		"usb":             usb.Status(),
	})
}

// hQR — QR-код с реальным (уже с учётом отката порта) адресом сервера как
// обычным текстом (Опус-ревью 14.09.2026, пункт 6). Только для чтения любой
// камерой/сканером — руками вписать адрес в приложении всё равно надо,
// автоматического считывания на телефоне это не добавляет (для этого
// понадобилось бы менять apps/mobile — вне рамок сегодняшней правки).
func (s *Service) hQR(w http.ResponseWriter, r *http.Request) {
	addr, _ := s.currentAddr()
	// Голый "хост:порт", тем же текстом, что в поле «Адрес для телефона» в
	// Настройках — Alex вписывает именно это в приложение, без http://.
	png, err := qrcode.Encode(addr, qrcode.Medium, 320)
	if err != nil {
		http.Error(w, "не построить QR: "+err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store") // адрес может смениться при следующем запуске/откате порта
	_, _ = w.Write(png)
}

func (s *Service) hCatalog(w http.ResponseWriter, r *http.Request) {
	tree, err := s.buildCatalogTree()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, tree)
}

// hCatalogFlat — весь каталог плоским списком (id/artist/title/album/cover/
// has_fp у каждого трека) — для плиток «один альбом = одна плитка», как в
// iTunes (Alex TG 14.09.2026). Дерево папок (`/api/catalog`) для этого не
// годится: музыка часто лежит в одной плоской папке без под-папок по
// альбомам, а плитки нужно строить по тегу «альбом» из самих файлов, не по
// структуре каталога на диске.
func (s *Service) hCatalogFlat(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.CatalogList(1_000_000)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, rows)
}

// hCatalogNewSince — какие треки появились в каталоге после ?since=
// (RFC3339) — для точки «новое» на плитке альбома (Alex TG 14.09.2026).
func (s *Service) hCatalogNewSince(w http.ResponseWriter, r *http.Request) {
	since := strings.TrimSpace(r.URL.Query().Get("since"))
	if since == "" {
		writeJSON(w, []localdb.NewSinceItem{})
		return
	}
	items, err := s.db.TracksCreatedSince(since)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, items)
}

const settingWatchDir = "watch_dir"

// hWatchDirGet/hWatchDirSet — папка, которую программа сама проверяет на
// новые песни при возврате фокуса окна (Alex TG 14.09.2026: «опрашивать
// папку, которую я указал... если поменяю папку, то и другую будет
// опрашивать»). Меняется автоматически при каждом «Выбрать папку» —
// отдельно её нигде вручную вводить не нужно, только видно в «Настройках».
func (s *Service) hWatchDirGet(w http.ResponseWriter, r *http.Request) {
	dir, _, err := s.db.GetSetting(settingWatchDir)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]string{"dir": dir})
}

func (s *Service) hWatchDirSet(w http.ResponseWriter, r *http.Request) {
	dir := strings.TrimSpace(r.URL.Query().Get("dir"))
	if dir == "" {
		http.Error(w, "нет ?dir", 400)
		return
	}
	if err := s.db.SetSetting(settingWatchDir, dir); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]string{"dir": dir})
}

// hRoots — корневые папки каталога для «Настроек»: путь + сколько песен и
// сколько из них с отпечатком. Считается из того же дерева, что и «Каталог».
func (s *Service) hRoots(w http.ResponseWriter, r *http.Request) {
	tree, err := s.buildCatalogTree()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	type root struct {
		Path   string `json:"path"`
		Tracks int    `json:"tracks"`
		WithFP int    `json:"with_fp"`
	}
	out := make([]root, 0, len(tree))
	for _, n := range tree {
		out = append(out, root{Path: n.Path, Tracks: n.Tracks, WithFP: n.WithFP})
	}
	writeJSON(w, out)
}

func (s *Service) hSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	lim := atoiDef(r.URL.Query().Get("limit"), 60)
	if q == "" {
		writeJSON(w, []localdb.CatalogTrack{})
		return
	}
	rows, err := s.db.CatalogSearch(q, lim)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, rows)
}

// deviceRow — строка списка «Устройства» для окна: всё из БД + «качает
// прямо сейчас» (это в памяти /v1-сервера, не в БД).
type deviceRow struct {
	localdb.DeviceInfo
	Download *db.DownloadProgress `json:"download,omitempty"`
}

func (s *Service) hDevices(w http.ResponseWriter, r *http.Request) {
	list, err := s.db.ListDevices()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	out := make([]deviceRow, len(list))
	for i, d := range list {
		out[i].DeviceInfo = d
		if s.phoneAPI != nil {
			out[i].Download = s.phoneAPI.DownloadProgress(d.ID)
		}
	}
	writeJSON(w, out)
}

// hDeviceDelete — убрать запись устройства из списка (Alex TG 15.09.2026:
// «зачем старые вообще нужны? может удалить?» — старая запись копится при
// переустановке приложения на телефоне, новый внутренний id каждый раз).
// Музыку/данные на самом телефоне не трогает — только запись в этой БД.
func (s *Service) hDeviceDelete(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if err := s.db.DeleteDevice(id); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Service) hLog(w http.ResponseWriter, r *http.Request) {
	list, err := s.db.RecentServerLog(atoiDef(r.URL.Query().Get("limit"), 120))
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, list)
}

func (s *Service) hJobs(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.jobs.Status())
}

func (s *Service) hScan(w http.ResponseWriter, r *http.Request) {
	dir := strings.TrimSpace(r.URL.Query().Get("dir"))
	if dir == "" {
		http.Error(w, "нет ?dir", 400)
		return
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		http.Error(w, "папка не найдена: "+dir, 400)
		return
	}
	id := s.jobs.StartScan(dir)
	writeJSON(w, map[string]string{"job": id})
}

func (s *Service) hReindex(w http.ResponseWriter, r *http.Request) {
	if s.eng == nil {
		http.Error(w, "модель отпечатков не загружена", 409)
		return
	}
	id := s.jobs.StartReindex()
	writeJSON(w, map[string]string{"job": id})
}

func (s *Service) hStop(w http.ResponseWriter, r *http.Request) {
	s.jobs.CancelAll()
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Service) hAudio(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	path, ok, err := s.db.TrackFilePath(id)
	if err != nil || !ok {
		http.Error(w, "нет трека", 404)
		return
	}
	local := s.localPath(path)
	f, err := os.Open(local)
	if err != nil {
		http.Error(w, "файл недоступен", 502)
		return
	}
	defer f.Close()
	fi, _ := f.Stat()
	w.Header().Set("Content-Type", "audio/mpeg")
	http.ServeContent(w, r, filepath.Base(local), fi.ModTime(), f)
}

// hCover — обложка, вшитая в сам файл трека (ID3). Нет — 404, фронт покажет
// заглушку. Для окна-плеера.
func (s *Service) hCover(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	path, ok, err := s.db.TrackFilePath(id)
	if err != nil || !ok {
		http.Error(w, "нет трека", 404)
		return
	}
	local := s.localPath(path)
	c := embeddedCover(local)
	if c == nil {
		// нет в самом файле — картинка в папке альбома, потом найденная поиском (см. coverart)
		if p, ok := coverart.FolderImage(local); ok {
			w.Header().Set("Cache-Control", "max-age=86400")
			http.ServeFile(w, r, p)
			return
		}
		if p, ok := coverart.Found(s.foundCoversDir(), id); ok {
			w.Header().Set("Cache-Control", "max-age=86400")
			http.ServeFile(w, r, p)
			return
		}
		http.Error(w, "нет обложки", 404)
		return
	}
	w.Header().Set("Content-Type", c.mime)
	w.Header().Set("Cache-Control", "max-age=86400")
	_, _ = w.Write(c.data)
}

// foundCoversDir — папка с обложками, найденными поиском в интернете
// (<id трека>.jpg): рядом с базой, как generated_covers (20.09.2026).
func (s *Service) foundCoversDir() string {
	return filepath.Join(filepath.Dir(s.dbPath), "found_covers")
}

// localPath — канонический путь -> путь на этой машине. Пока считаем, что exe
// крутится на том же ПК, где лежит E:\soundflow-data (сервер). Переопределяется
// через SOUNDFLOW_AUDIO_ROOT (заменяет префикс E:\soundflow-data).
func (s *Service) localPath(canon string) string {
	root := os.Getenv("SOUNDFLOW_AUDIO_ROOT")
	if root == "" {
		return canon
	}
	low := strings.ToLower(strings.ReplaceAll(canon, "/", "\\"))
	const pre = `e:\soundflow-data`
	if strings.HasPrefix(low, pre) {
		return filepath.Join(root, canon[len(pre):])
	}
	return canon
}

// ---------------- дерево каталога по папкам ----------------

type FolderNode struct {
	Name     string        `json:"name"`
	Path     string        `json:"path"`
	Kind     string        `json:"kind"` // root | folder | album
	Tracks   int           `json:"tracks"`
	WithFP   int           `json:"with_fp"`
	Children []*FolderNode `json:"children,omitempty"`
	Items    []leafTrack   `json:"items,omitempty"`
}

type leafTrack struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Artist      string `json:"artist"`
	DurationSec int    `json:"duration_sec"`
	BitrateKbps int    `json:"bitrate_kbps"`
	HasFP       bool   `json:"has_fp"`
}

func (s *Service) buildCatalogTree() ([]*FolderNode, error) {
	rows, err := s.db.SQL().Query(`
		SELECT t.id, t.artist, t.title, COALESCE(tf.duration_sec, t.duration_sec, 0),
		       COALESCE(tf.bitrate_kbps, 0), tf.file_path,
		       (t.feature_vector IS NOT NULL)
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		WHERE lm.kind IS NOT 'blocked'
		ORDER BY tf.file_path`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	roots := map[string]*FolderNode{}
	var order []string
	for rows.Next() {
		var id, artist, title, path string
		var dur, br int
		var hasFP bool
		if err := rows.Scan(&id, &artist, &title, &dur, &br, &path, &hasFP); err != nil {
			return nil, err
		}
		rootKey, rest := splitRoot(path)
		rn := roots[rootKey]
		if rn == nil {
			rn = &FolderNode{Name: rootKey, Path: rootKey, Kind: "root"}
			roots[rootKey] = rn
			order = append(order, rootKey)
		}
		// rest — сегменты папок + имя файла; последний сегмент отбрасываем (файл)
		segs := splitSegs(rest)
		var folders []string
		if len(segs) > 1 {
			folders = segs[:len(segs)-1]
		}
		cur := rn
		accum := rootKey
		for i, seg := range folders {
			accum = accum + "\\" + seg
			var child *FolderNode
			for _, c := range cur.Children {
				if c.Name == seg {
					child = c
					break
				}
			}
			if child == nil {
				kind := "folder"
				if i == len(folders)-1 {
					kind = "album"
				}
				child = &FolderNode{Name: seg, Path: accum, Kind: kind}
				cur.Children = append(cur.Children, child)
			}
			cur = child
		}
		cur.Items = append(cur.Items, leafTrack{
			ID: id, Title: title, Artist: artist,
			DurationSec: dur, BitrateKbps: br, HasFP: hasFP,
		})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out := make([]*FolderNode, 0, len(order))
	for _, k := range order {
		n := roots[k]
		rollUp(n)
		sortTree(n)
		out = append(out, n)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, nil
}

func rollUp(n *FolderNode) (tracks, withFP int) {
	tracks, withFP = len(n.Items), 0
	for _, it := range n.Items {
		if it.HasFP {
			withFP++
		}
	}
	for _, c := range n.Children {
		t, f := rollUp(c)
		tracks += t
		withFP += f
	}
	n.Tracks, n.WithFP = tracks, withFP
	return
}

func sortTree(n *FolderNode) {
	sort.Slice(n.Children, func(i, j int) bool { return n.Children[i].Name < n.Children[j].Name })
	sort.Slice(n.Items, func(i, j int) bool { return n.Items[i].Title < n.Items[j].Title })
	for _, c := range n.Children {
		sortTree(c)
	}
}

func splitRoot(p string) (root, rest string) {
	p = strings.ReplaceAll(p, "/", "\\")
	low := strings.ToLower(p)
	for _, pre := range []string{`e:\soundflow-data\music`, `e:\soundflow-data\cache`, `e:\soundflow-data`} {
		if strings.HasPrefix(low, pre) {
			return p[:len(pre)], strings.TrimPrefix(p[len(pre):], "\\")
		}
	}
	// иначе — диск как корень
	if i := strings.Index(p, "\\"); i > 0 {
		return p[:i], p[i+1:]
	}
	return p, ""
}

func splitSegs(s string) []string {
	s = strings.Trim(strings.ReplaceAll(s, "/", "\\"), "\\")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\\")
}

// ---------------- утилиты ----------------

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func dataDir() string {
	if d := os.Getenv("LOCALAPPDATA"); d != "" {
		return filepath.Join(d, "SoundFlow")
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".soundflow")
}

func exeDir() string {
	if p, err := os.Executable(); err == nil {
		return filepath.Dir(p)
	}
	return "."
}

func atoiDef(s string, d int) int {
	if n, err := strconv.Atoi(s); err == nil && n > 0 {
		return n
	}
	return d
}

func localAddr(addr string) string {
	// ":8090" / "0.0.0.0:8090" / "127.0.0.1:8090" -> "<ip в домашней сети>:8090"
	// для показа в окне (этот адрес вписывают в телефон).
	port := addr
	if i := strings.LastIndex(addr, ":"); i >= 0 {
		port = addr[i:]
	}
	host := hostIP()
	if host == "" {
		host = "127.0.0.1"
	}
	return host + port
}
