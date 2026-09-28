package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"

	"soundflow/server/internal/appsettings"
	"soundflow/server/internal/yandexauth"
)

// Мастер первого запуска своей копии плеера (передача плеера другому человеку, Alex 27–28.09.2026):
// страница frontend/setup/index.html по шагам — папка с музыкой → вход в Яндекс (можно пропустить) →
// торренты → свой ВДС (setup_vds.go) → готово. Всё, что человек выбрал, пишется в settings.json рядом с базой
// (internal/appsettings) и сразу попадает в окружение процесса — перезапуск программы не нужен.
// Все ручки — только с этого компьютера.

type setupState struct {
	mu     sync.Mutex
	yandex yandexLogin
}

// yandexLogin — идущий вход в Яндекс кодом на экране.
type yandexLogin struct {
	State  string    `json:"state"` // "", waiting, ok, error
	Code   string    `json:"code,omitempty"`
	URL    string    `json:"url,omitempty"`
	Error  string    `json:"error,omitempty"`
	Until  time.Time `json:"until"`
	cancel context.CancelFunc
}

var setup setupState

func (s *Service) mountSetup(r chi.Router) {
	r.Get("/api/setup/state", localOnly(s.hSetupState))
	r.Post("/api/setup/music", localOnly(s.hSetupMusic))
	r.Post("/api/setup/yandex/start", localOnly(s.hSetupYandexStart))
	r.Get("/api/setup/yandex/status", localOnly(s.hSetupYandexStatus))
	r.Post("/api/setup/torrents", localOnly(s.hSetupTorrents))
	r.Post("/api/setup/vds/prepare", localOnly(s.hSetupVdsPrepare))
	r.Post("/api/setup/vds/check", localOnly(s.hSetupVdsCheck))
	r.Post("/api/setup/phone", localOnly(s.hSetupPhone))
	r.Get("/api/setup/apk-qr.png", localOnly(s.hSetupApkQR))
	r.Post("/api/setup/finish", localOnly(s.hSetupFinish))
	r.Get("/api/pc-update", localOnly(s.hPCUpdateCheck)) // обновление программы (pcupdate.go)
	r.Post("/api/pc-update", localOnly(s.hPCUpdateInstall))
}

// setupNeeded — показывать ли мастер: не пройден, и это новая установка (настроек ещё нет и каталог
// пуст — у давно работающего компьютера без settings.json мастер не выскакивает).
func (s *Service) setupNeeded() bool {
	dir := dataDir()
	if st, ok := appsettings.Load(dir); ok {
		return !st.SetupDone
	}
	c, err := s.db.Counts()
	return err == nil && c.Tracks == 0
}

// updateSettings — прочитать, поправить и сохранить settings.json, затем перенести в окружение.
func updateSettings(fn func(*appsettings.Settings)) (appsettings.Settings, error) {
	dir := dataDir()
	st, _ := appsettings.Load(dir)
	fn(&st)
	if err := appsettings.Save(dir, st); err != nil {
		return st, err
	}
	for k, v := range appsettings.Env(st, dir) {
		_ = os.Setenv(k, v)
	}
	return st, nil
}

func (s *Service) hSetupState(w http.ResponseWriter, r *http.Request) {
	st, _ := appsettings.Load(dataDir())
	writeJSON(w, map[string]any{
		"needed":       s.setupNeeded(),
		"musicDir":     st.MusicDir,
		"yandex":       st.YandexToken != "",
		"torrents":     st.QbtUser != "",
		"vds":          st.Relay.Host != "",
		"qbtInstalled": qbtExe() != "",
		"downloader":   s.dl != nil,
	})
}

// POST /api/setup/music {"dir": "D:\\Музыка"} — корень музыки: внутри создаются «Яндекс» и
// «Торренты» (туда качалка кладёт новое), вся папка ставится на сканирование в каталог.
func (s *Service) hSetupMusic(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Dir string `json:"dir"`
	}
	_ = json.NewDecoder(r.Body).Decode(&in)
	dir := strings.TrimSpace(in.Dir)
	if fi, err := os.Stat(dir); dir == "" || err != nil || !fi.IsDir() {
		http.Error(w, "Папка не найдена: "+dir, 400)
		return
	}
	for _, sub := range []string{"Яндекс", "Торренты"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o755); err != nil {
			http.Error(w, "Не удалось создать папку «"+sub+"»: "+err.Error(), 500)
			return
		}
	}
	if _, err := updateSettings(func(st *appsettings.Settings) { st.MusicDir = dir }); err != nil {
		http.Error(w, "Настройки не сохранились: "+err.Error(), 500)
		return
	}
	id := s.jobs.StartScan(dir)
	s.jobs.keep(id)
	writeJSON(w, map[string]string{"job": id})
}

// POST /api/setup/yandex/start — получить код и ждать, пока человек введёт его на ya.ru/device.
func (s *Service) hSetupYandexStart(w http.ResponseWriter, r *http.Request) {
	host, _ := os.Hostname()
	code, err := yandexauth.Start(r.Context(), "soundflow-"+appsettings.RandomSecret(10), "SoundFlow "+host)
	if err != nil {
		http.Error(w, "Яндекс не ответил: "+err.Error(), 502)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(code.ExpiresIn)*time.Second)
	setup.mu.Lock()
	if setup.yandex.cancel != nil {
		setup.yandex.cancel()
	}
	setup.yandex = yandexLogin{State: "waiting", Code: code.UserCode, URL: code.URL,
		Until: time.Now().Add(time.Duration(code.ExpiresIn) * time.Second), cancel: cancel}
	setup.mu.Unlock()
	go s.waitYandex(ctx, code)
	s.hSetupYandexStatus(w, r)
}

func (s *Service) waitYandex(ctx context.Context, code yandexauth.Code) {
	defer func() {
		setup.mu.Lock()
		if setup.yandex.State == "waiting" {
			setup.yandex.State, setup.yandex.Error = "error", "Время на ввод кода вышло — получите новый код."
		}
		setup.mu.Unlock()
	}()
	tick := time.NewTicker(time.Duration(code.Interval) * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		tok, err := yandexauth.Poll(ctx, code.DeviceCode)
		if errors.Is(err, yandexauth.ErrPending) || (err != nil && ctx.Err() == nil && isNetErr(err)) {
			continue
		}
		setup.mu.Lock()
		if err != nil {
			setup.yandex.State, setup.yandex.Error = "error", err.Error()
		} else if _, serr := updateSettings(func(st *appsettings.Settings) { st.YandexToken = tok }); serr != nil {
			setup.yandex.State, setup.yandex.Error = "error", "Настройки не сохранились: "+serr.Error()
		} else {
			setup.yandex.State = "ok"
			s.dl.restart()  // качалка возьмёт токен из окружения
			s.seeder.Kick() // и сразу — начальный вкус из его лайков (tasteseed.go)
		}
		setup.mu.Unlock()
		return
	}
}

// isNetErr — сбой связи (не ответ Яндекса): стоит повторить опрос, а не бросать вход.
func isNetErr(err error) bool {
	return !strings.HasPrefix(err.Error(), "Яндекс")
}

func (s *Service) hSetupYandexStatus(w http.ResponseWriter, r *http.Request) {
	setup.mu.Lock()
	y := setup.yandex
	setup.mu.Unlock()
	writeJSON(w, y)
}

// POST /api/setup/torrents — включить в qBittorrent вход для качалки: свой логин и случайный пароль
// в настройках qBittorrent и в settings.json. qBittorrent должен быть закрыт — при выходе он
// перезаписывает свои настройки и затёр бы новые.
func (s *Service) hSetupTorrents(w http.ResponseWriter, r *http.Request) {
	if qbtExe() == "" {
		http.Error(w, "qBittorrent не установлен. Установите его (установщик SoundFlow ставит его галочкой «Торренты») и повторите.", 409)
		return
	}
	if qBittorrentReachable() || qbtRunning() {
		http.Error(w, "Закройте qBittorrent (значок в трее → «Выход») и нажмите ещё раз.", 409)
		return
	}
	ini := filepath.Join(os.Getenv("APPDATA"), "qBittorrent", "qBittorrent.ini")
	user, pass := "soundflow", appsettings.RandomSecret(20)
	if err := appsettings.WriteQbtWebUI(ini, user, pass); err != nil {
		http.Error(w, "Настройки qBittorrent не записались: "+err.Error(), 500)
		return
	}
	if _, err := updateSettings(func(st *appsettings.Settings) { st.QbtUser, st.QbtPass = user, pass }); err != nil {
		http.Error(w, "Настройки не сохранились: "+err.Error(), 500)
		return
	}
	s.dl.restart()
	if err := ensureQBittorrent(); err != nil {
		http.Error(w, err.Error(), 502)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Service) hSetupFinish(w http.ResponseWriter, r *http.Request) {
	if _, err := updateSettings(func(st *appsettings.Settings) { st.SetupDone = true }); err != nil {
		http.Error(w, "Настройки не сохранились: "+err.Error(), 500)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}
