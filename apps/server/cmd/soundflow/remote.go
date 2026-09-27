package main

// Режим «только плеер» (Alex TG 26.09.2026: «сервер плеера крутится на Linux-сервере, а сам плеер — на ПК
// brain»). Окно SoundFlow.exe не поднимает свой сервер (базу, отпечатки, телефонный API), а отдаёт тот же
// вшитый интерфейс и пересылает все его запросы (/api/*, /audio/*, /v1/*) на сервер по SOUNDFLOW_REMOTE.
//
// Команды «только с этого компьютера» (удалить навсегда, план телефона, пары…) сервер принимает от такого
// окна по общему секрету SOUNDFLOW_WINDOW_TOKEN: окно кладёт его в заголовок, сервер сверяет со своим.
// Адрес ПК тут не годится — он может смениться, а секрет с чужого устройства сети не подделать.

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

const windowTokenHeader = "X-SoundFlow-Window-Token"

// playerConfigName — файл настроек режима «только плеер» рядом с SoundFlow.exe. Вместо запуска через .cmd с
// переменными (Alex TG 26.09.2026: «чтобы запуск был красиво, не через cmd»): exe открывают ярлыком, а адрес
// сервера и секрет окна он читает сам отсюда. Переменные окружения, если заданы, главнее файла.
const playerConfigName = "player.json"

type playerConfig struct {
	Server string `json:"server"` // http://192.168.1.73:8090
	Token  string `json:"token"`  // тот же SOUNDFLOW_WINDOW_TOKEN, что на сервере
}

// loadPlayerConfig — настройки из player.json в папке dir (обычно папка exe); нет файла — пустые.
func loadPlayerConfig(dir string) playerConfig {
	var c playerConfig
	if b, err := os.ReadFile(filepath.Join(dir, playerConfigName)); err == nil {
		_ = json.Unmarshal(b, &c)
	}
	return c
}

// remoteServerURL — адрес сервера для режима «только плеер»; "" — обычный режим (сервер в этом же окне).
func remoteServerURL() string {
	v := os.Getenv("SOUNDFLOW_REMOTE")
	if v == "" {
		v = loadPlayerConfig(exeDir()).Server
	}
	return strings.TrimRight(strings.TrimSpace(v), "/")
}

// windowToken — секрет, который окно «только плеер» кладёт в запросы: из окружения или из player.json.
func windowToken() string {
	if v := os.Getenv("SOUNDFLOW_WINDOW_TOKEN"); v != "" {
		return v
	}
	return loadPlayerConfig(exeDir()).Token
}

// remoteProxy — пересылка запросов окна на сервер с секретом окна в заголовке.
func remoteProxy(remote string) (http.Handler, error) {
	u, err := url.Parse(remote)
	if err != nil {
		return nil, err
	}
	token := windowToken()
	p := httputil.NewSingleHostReverseProxy(u)
	base := p.Director
	p.Director = func(r *http.Request) {
		base(r)
		r.Host = u.Host
		r.Header.Del(windowTokenHeader)
		if token != "" {
			r.Header.Set(windowTokenHeader, token)
		}
	}
	p.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		http.Error(w, "сервер SoundFlow ("+remote+") не отвечает: "+err.Error(), http.StatusBadGateway)
	}
	return p, nil
}

// fromTrustedWindow — запрос пришёл от окна «только плеер» с верным секретом (см. SOUNDFLOW_WINDOW_TOKEN
// на сервере). Пустой секрет на сервере — режим выключен, никого не пускаем.
func fromTrustedWindow(r *http.Request) bool {
	want := os.Getenv("SOUNDFLOW_WINDOW_TOKEN")
	got := r.Header.Get(windowTokenHeader)
	return want != "" && got != "" && subtle.ConstantTimeCompare([]byte(want), []byte(got)) == 1
}
