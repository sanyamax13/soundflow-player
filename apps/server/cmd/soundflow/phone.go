package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/dhowden/tag"
	"github.com/go-chi/chi/v5"

	"soundflow/server/internal/acquire"
	"soundflow/server/internal/api"
	"soundflow/server/internal/config"
	"soundflow/server/internal/litestore"
	"soundflow/server/internal/music"
	"soundflow/server/internal/pathmap"
	"soundflow/server/internal/sidecar"
)

// maxPortFallbackTries — если настроенный порт занят другой программой (как
// TorrServer занял 8090 у Alex 13.09.2026), пробуем следующие по счёту порты
// вместо того, чтобы тихо падать и оставлять окно врать «сервер работает»
// (Опус-ревью 14.09.2026, пункт 1).
const maxPortFallbackTries = 5

// listenWithFallback — слушать addr ("0.0.0.0:8090", ":8090"...); если порт
// занят — пробовать port+1, port+2, ... до maxPortFallbackTries раз. Возвращает
// реально открытый listener и адрес, на котором он висит.
func listenWithFallback(addr string, maxTries int) (net.Listener, string, error) {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, "", err
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		// нечисловой порт — редкость, пробуем как есть один раз
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			return nil, "", err
		}
		return ln, addr, nil
	}
	var lastErr error
	for i := 0; i < maxTries; i++ {
		tryAddr := net.JoinHostPort(host, strconv.Itoa(port+i))
		ln, err := net.Listen("tcp", tryAddr)
		if err == nil {
			return ln, tryAddr, nil
		}
		lastErr = err
	}
	return nil, "", fmt.Errorf("порты %d..%d заняты: %w", port, port+maxTries-1, lastErr)
}

// startPhoneServer поднимает HTTP на :8090:
//   - /v1/*  — телефонный + админский API. Тот же проверенный код, что у старого
//     сервера (internal/api), только база — SQLite через litestore, а не Postgres.
//   - /api/* — ручки окна-дашборда (тот же дашборд открывается и браузером).
//   - /*     — вшитый frontend.
//
// Acquire («Добавить музыку») пока не подключён — до перевода Python-качалки в
// тонкий сервис; соответствующие ручки честно отвечают 503 (s.Acquire == nil).
// buildPhoneRouter — полный роутер телефона (/v1/* + /api/* + статика окна):
// общий и для обычного Wi-Fi-слушателя (ниже), и для будущего удалённого
// канала через VDS (Alex TG 24.09.2026 — вместо Tailscale, см.
// docs/TAILSCALE-REMOTE-ACCESS-PLAN.md) — тот же функционал, просто другой
// путь доступа.
func (s *Service) buildPhoneRouter() chi.Router {
	cfg := config.Load()

	pm := cfg.PathMap
	if len(pm.LocalRoots()) == 0 {
		if root := os.Getenv("SOUNDFLOW_AUDIO_ROOT"); root != "" {
			pm = pathmap.New(
				pathmap.Pair{Canonical: `E:\soundflow-data\cache`, Local: filepath.Join(root, "cache")},
				pathmap.Pair{Canonical: `E:\soundflow-data\music`, Local: filepath.Join(root, "music")},
			)
		}
	}

	// ИИ-нарисованные обложки (этап 28): по умолчанию — папка рядом с базой
	// (E:\soundflow-data\generated_covers), env перебивает. Раньше их отдавал
	// fg; курс «сервер в одном приложении» — отдаём отсюда.
	gcov := cfg.GeneratedCoversDir
	if gcov == "" {
		gcov = filepath.Join(filepath.Dir(s.dbPath), "generated_covers")
	}

	store := litestore.New(s.db)
	apiSrv := &api.Server{
		DB:                 store,
		Music:              music.New(cfg.MusicDir),
		PathMap:            pm,
		StartedAt:          s.startedAt,
		GeneratedCoversDir: gcov,
		FoundCoversDir:     s.foundCoversDir(),
		// Новая скачанная песня сама ложится в план телефона (см. autoplan.go).
		OnTrackAdded: s.onTrackAdded,
		// Убранное на телефоне не стирается само, а ждёт подтверждения в окне
		// (Alex TG 19943/19948, см. removals.go).
		EraseGate: removalGate{db: s.db},
	}
	s.phoneAPI = apiSrv // окну нужен для строки «качает прямо сейчас»
	s.store = store     // окну нужен для acquire («Найти трек»)
	s.pm = pm

	// «Добавить музыку»: скачивание — тонкий Python-сайдкар (Яндекс/musify/
	// торренты), отпечаток скачанного — локально ONNX (localFinder).
	if cfg.SidecarURL != "" {
		apiSrv.Acquire = &acquire.Service{
			DB:     store,
			Finder: &localFinder{Client: sidecar.New(cfg.SidecarURL), eng: s.eng, pm: pm},
		}
	}

	r := chi.NewRouter()
	// /v1/* целиком отдаём проверенному роутеру internal/api (он сам маршрутит
	// от /v1). chi.Handle не срезает префикс — путь приходит как есть.
	r.Handle("/v1/*", apiSrv.Router())

	// то же окно доступно и в обычном браузере: /api/* + вшитый frontend
	s.mountAPI(r)
	r.Handle("/*", s.staticHandler())
	return r
}

func (s *Service) startPhoneServer() {
	r := s.buildPhoneRouter()

	ln, boundAddr, err := listenWithFallback(s.phoneAddr, maxPortFallbackTries)
	if err != nil {
		s.mu.Lock()
		s.phoneListening = false
		s.phoneListenErr = err.Error()
		s.mu.Unlock()
		_ = s.db.AddServerLog("error", "", "", "телефонный API не смог начать слушать ("+s.phoneAddr+"): "+err.Error(), 0)
		return
	}
	s.mu.Lock()
	s.phoneListening = true
	s.phoneBoundAddr = boundAddr
	s.phoneListenErr = ""
	s.mu.Unlock()
	if boundAddr != s.phoneAddr {
		_ = s.db.AddServerLog("info", "", "", "порт "+s.phoneAddr+" занят другой программой, встал на "+boundAddr, 0)
	}

	s.phoneSrv = &http.Server{Handler: r, ReadHeaderTimeout: 10 * time.Second}
	_ = s.db.AddServerLog("info", "", "", "телефонный API слушает "+boundAddr, 0)
	// USB-туннель (Alex: «только USB») — держим adb reverse живым, пока
	// телефон в кабеле, на РЕАЛЬНО занятом порту (не на настроенном, если
	// пришлось откатиться на следующий свободный). adb.exe нет рядом →
	// тихо выключено, только Wi-Fi.
	startUSBTunnel(boundAddr)

	if err := s.phoneSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
		s.mu.Lock()
		s.phoneListening = false
		s.phoneListenErr = err.Error()
		s.mu.Unlock()
		_ = s.db.AddServerLog("error", "", "", "телефонный API упал: "+err.Error(), 0)
	}
}

type cover struct {
	mime string
	data []byte
}

func embeddedCover(path string) *cover {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	m, err := tag.ReadFrom(f)
	if err != nil || m == nil || m.Picture() == nil {
		return nil
	}
	p := m.Picture()
	mime := p.MIMEType
	if mime == "" {
		mime = "image/jpeg"
	}
	return &cover{mime: mime, data: p.Data}
}
