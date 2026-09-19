package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Готовое окно программы (WebView2) не даёт заглянуть внутрь: порта отладки у него нет. Для разбора
// «песня из «Открытий» в окне не играет и без ошибки» (Alex TG 20095, 20.09.2026) окно дописывает
// события плеера в файл рядом с базой (window-debug.log) — читаю его я, а не гадаю. Только с этого
// компьютера (localOnly), файл не растёт дольше мегабайта.

const (
	clientLogFile = "window-debug.log"
	clientLogMax  = 1 << 20 // больше — старое откладываем в .old
	clientLogLine = 400     // символов в одной записи
)

var clientLogMu sync.Mutex

// hClientLog — POST /api/client-log {"what": "..."}.
func (s *Service) hClientLog(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<14)
	var in struct {
		What string `json:"what"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	what := strings.Join(strings.Fields(in.What), " ")
	if what == "" {
		http.Error(w, "нужно поле what", 400)
		return
	}
	if rs := []rune(what); len(rs) > clientLogLine {
		what = string(rs[:clientLogLine])
	}
	if err := appendClientLog(filepath.Join(filepath.Dir(s.dbPath), clientLogFile), what); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func appendClientLog(path, what string) error {
	clientLogMu.Lock()
	defer clientLogMu.Unlock()
	if st, err := os.Stat(path); err == nil && st.Size() > clientLogMax {
		_ = os.Rename(path, path+".old")
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(time.Now().Format("2006-01-02 15:04:05.000") + "  " + what + "\n")
	return err
}
