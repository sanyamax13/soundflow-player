package main

import (
	"net/http"
	"os"
	"time"

	"strconv"

	"soundflow/server/internal/appsettings"
)

// Живой монитор системы (Alex 28.09.2026: «чтобы онлайн видеть, что работает, что нет, где затык»).
// Отдаёт состояние узлов схемы; страница frontend/status.html красит их зелёным/красным и опрашивает
// раз в несколько секунд. Ничего не меняет — только смотрит.

type nodeStatus struct {
	State  string `json:"state"` // ok | warn | err | off
	Detail string `json:"detail"`
}

func (s *Service) hStatusMap(w http.ResponseWriter, r *http.Request) {
	out := map[string]nodeStatus{}

	// Сервер — раз отвечает, значит жив.
	out["server"] = nodeStatus{"ok", "работает"}

	// База.
	if c, err := s.db.Counts(); err == nil {
		out["db"] = nodeStatus{"ok", itoa64(c.Tracks) + " песен"}
	} else {
		out["db"] = nodeStatus{"err", "не читается"}
	}

	// Качалка.
	if base := s.sidecarURL(); base != "" {
		out["downloader"] = nodeStatus{"ok", "на связи"}
	} else {
		out["downloader"] = nodeStatus{"warn", "запускается / нет"}
	}

	// qBittorrent.
	if qBittorrentReachable() {
		out["qbittorrent"] = nodeStatus{"ok", "Web UI отвечает"}
	} else {
		out["qbittorrent"] = nodeStatus{"warn", "не запущен"}
	}

	// Яндекс — по наличию токена.
	st, _ := appsettings.Load(dataDir())
	if os.Getenv("YANDEX_MUSIC_TOKEN") != "" || st.YandexToken != "" {
		out["yandex"] = nodeStatus{"ok", "вход есть"}
	} else {
		out["yandex"] = nodeStatus{"off", "не вошли (не обязателен)"}
	}

	// Канал до ВДС.
	switch {
	case env("SOUNDFLOW_RELAY_HOST", "") == "" && st.Relay.Host == "":
		out["vds"] = nodeStatus{"off", "не настроен"}
	case s.relayUp.Load():
		out["vds"] = nodeStatus{"ok", "канал поднят"}
	default:
		out["vds"] = nodeStatus{"warn", "переподключается"}
	}

	// Телефон — когда последний раз выходил на связь.
	if devs, err := s.db.ListDevices(); err == nil && len(devs) > 0 && devs[0].LastSyncAt != nil {
		ago := time.Since(*devs[0].LastSyncAt)
		switch {
		case ago < 3*time.Minute:
			out["phone"] = nodeStatus{"ok", "на связи"}
		case ago < 24*time.Hour:
			out["phone"] = nodeStatus{"warn", "был " + since(ago) + " назад"}
		default:
			out["phone"] = nodeStatus{"off", "давно не выходил"}
		}
	} else {
		out["phone"] = nodeStatus{"off", "ещё не подключался"}
	}

	// Хранители (обложки, настроение, бас…) — работают, пока сервер жив.
	out["keepers"] = nodeStatus{"ok", "работают фоном"}

	writeJSON(w, map[string]any{"nodes": out, "at": time.Now().Format(time.RFC3339)})
}

func since(d time.Duration) string {
	if d < time.Hour {
		return itoa(int(d.Minutes())) + " мин"
	}
	return itoa(int(d.Hours())) + " ч"
}

func itoa(n int) string     { return strconv.Itoa(n) }
func itoa64(n int64) string { return strconv.FormatInt(n, 10) }
