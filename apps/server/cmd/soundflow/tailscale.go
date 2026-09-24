package main

import (
	"net/http"
	"os"
	"path/filepath"

	"tailscale.com/tsnet"
)

// Удалённый доступ из любой сети (Alex TG 24.09.2026,
// docs/TAILSCALE-REMOTE-ACCESS-PLAN.md) — Tailscale встроен прямо в
// программу (tsnet, официальная Go-библиотека Tailscale), отдельно
// ставить ничего не нужно. Тот же роутер, что и обычный Wi-Fi-слушатель
// (buildPhoneRouter, phone.go) — весь функционал (каталог, Открытия,
// Волна, синхронизация) доступен тем же способом, просто по другой сети.
//
// Без ключа и без сохранённого раньше состояния — тихо выключено (как
// качалка/модель): это не ошибка, просто Alex ещё не настраивал
// Tailscale. Настройка — TS_AUTHKEY переменной окружения (см. план:
// ключ с тегом в аккаунте Tailscale, никогда не в git). После первого
// успешного входа состояние сохраняется на диск (Dir ниже) — второй раз
// ключ не нужен, каждый следующий запуск переподключается сам.

const tailscaleHostname = "soundflow"

func (s *Service) startTailscale() {
	dir := filepath.Join(s.dataDir, "tailscale")
	key := os.Getenv("TS_AUTHKEY")
	if key == "" {
		if _, err := os.Stat(dir); err != nil {
			return // ни разу не настраивали Tailscale — тихо выключено
		}
	}

	ts := &tsnet.Server{
		Dir:      dir,
		Hostname: tailscaleHostname,
		AuthKey:  key,
	}
	if err := ts.Start(); err != nil {
		_ = s.db.AddServerLog("error", "", "", "Tailscale не поднялся: "+err.Error(), 0)
		return
	}
	ln, err := ts.Listen("tcp", ":80")
	if err != nil {
		_ = s.db.AddServerLog("error", "", "", "Tailscale поднялся, но не смог слушать: "+err.Error(), 0)
		_ = ts.Close()
		return
	}
	s.tailscale = ts
	r := s.buildPhoneRouter()
	srv := &http.Server{Handler: r}
	s.tailscaleSrv = srv
	_ = s.db.AddServerLog("info", "", "", "Tailscale включён — программа доступна из любой сети (имя узла: "+tailscaleHostname+")", 0)
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			_ = s.db.AddServerLog("error", "", "", "Tailscale-слушатель упал: "+err.Error(), 0)
		}
	}()
}

func (s *Service) stopTailscale() {
	if s.tailscaleSrv != nil {
		_ = s.tailscaleSrv.Close()
	}
	if s.tailscale != nil {
		_ = s.tailscale.Close()
	}
}
