// Package appsettings — настройки своей копии SoundFlow из settings.json.
package appsettings

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// Настройки своей копии SoundFlow (передача плеера другому человеку, Alex 27.09.2026): всё, что
// у Alex задано переменными окружения сервера, у другого человека лежит в одном файле
// %LocalAppData%\SoundFlow\settings.json. Файл вне папки программы — обновление программы его не
// трогает (его пишет мастер первого запуска). Переменная окружения, если задана, главнее файла:
// у Alex всё продолжает работать как раньше.
const FileName = "settings.json"

type RelaySettings struct {
	Host       string `json:"host"`       // адрес своего ВДС для SSH, «1.2.3.4:22»
	User       string `json:"user"`       // пользователь канала на ВДС
	Secret     string `json:"secret"`     // ключ, который телефон кладёт в запросы
	PublicURL  string `json:"publicUrl"`  // https-адрес, по которому телефон ходит снаружи
	RemoteBind string `json:"remoteBind"` // порт на ВДС, пусто — 127.0.0.1:8093
	KeyFile    string `json:"keyFile"`    // приватный SSH-ключ; пусто — relay_key рядом с базой
	HostKey    string `json:"hostKey"`    // отпечаток ВДС (необязательно)
}

type Settings struct {
	MusicDir    string        `json:"musicDir"`    // корень музыки: Яндекс и Торренты — папки внутри
	YandexToken string        `json:"yandexToken"` // токен Яндекс Музыки (вход в мастере)
	Addr        string        `json:"addr"`        // на чём слушать телефон, пусто — как по умолчанию
	QbtUser     string        `json:"qbtUser"`     // вход в Web UI qBittorrent (задаёт мастер)
	QbtPass     string        `json:"qbtPass"`
	Relay       RelaySettings `json:"relay"`
	SetupDone   bool          `json:"setupDone"` // мастер первого запуска пройден
}

func Load(dir string) (Settings, bool) {
	var s Settings
	b, err := os.ReadFile(filepath.Join(dir, FileName))
	if err != nil {
		return s, false
	}
	if json.Unmarshal(b, &s) != nil {
		return Settings{}, false
	}
	return s, true
}

// Env — какие переменные окружения задаёт файл настроек (пустые поля — не задаёт).
func Env(s Settings, dir string) map[string]string {
	m := map[string]string{}
	put := func(k, v string) {
		if v = strings.TrimSpace(v); v != "" {
			m[k] = v
		}
	}
	if root := strings.TrimSpace(s.MusicDir); root != "" {
		put("SOUNDFLOW_ALBUMS_ARTIST_ROOT", root)
		put("SOUNDFLOW_ALBUMS_DIR", filepath.Join(root, "Торренты"))
		put("SOUNDFLOW_TRACK_CACHE_DIR", filepath.Join(root, "Яндекс"))
	}
	put("YANDEX_MUSIC_TOKEN", s.YandexToken)
	put("SOUNDFLOW_ADDR", s.Addr)
	put("QBT_USER", s.QbtUser)
	put("QBT_PASS", s.QbtPass)
	r := s.Relay
	if strings.TrimSpace(r.Host) != "" {
		put("SOUNDFLOW_RELAY_HOST", r.Host)
		put("SOUNDFLOW_RELAY_USER", r.User)
		put("SOUNDFLOW_RELAY_SECRET", r.Secret)
		put("SOUNDFLOW_RELAY_PUBLIC_URL", r.PublicURL)
		put("SOUNDFLOW_RELAY_HOST_KEY", r.HostKey)
		bind := r.RemoteBind
		if strings.TrimSpace(bind) == "" {
			bind = "127.0.0.1:8093"
		}
		put("SOUNDFLOW_RELAY_REMOTE_BIND", bind)
		key := r.KeyFile
		if strings.TrimSpace(key) == "" {
			key = filepath.Join(dir, "relay_key")
		}
		put("SOUNDFLOW_RELAY_KEY_FILE", key)
	}
	return m
}

// Apply — перенести настройки из файла в окружение процесса (качалка получает их вместе с
// окружением). Уже заданные переменные не перебиваем.
func Apply(dir string) {
	s, ok := Load(dir)
	if !ok {
		return
	}
	for k, v := range Env(s, dir) {
		if os.Getenv(k) == "" {
			_ = os.Setenv(k, v)
		}
	}
}

// Save — записать настройки в dir\settings.json (через временный файл, чтобы при сбое не остался
// обрезанный файл). Файл с токеном и паролями — только для владельца.
func Save(dir string, s Settings) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := filepath.Join(dir, FileName+".tmp")
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, FileName))
}

// Exists — есть ли файл настроек (нет — нужен мастер первого запуска).
func Exists(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, FileName))
	return err == nil
}
