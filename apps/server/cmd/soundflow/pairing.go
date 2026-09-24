package main

import (
	"net/http"
	"os"
	"sync"
	"time"
)

// Первое подключение телефона — с подтверждением с обеих сторон (Alex TG
// 24.09.2026): раньше «Найти сервер самому» на телефоне молча сохранял
// первый ответивший адрес — для чужого компьютера/чужого человека это
// неочевидно и небезопасно («а вдруг не тот комп»). Теперь: на компьютере
// жмут «Подключить телефон» — открывается двухминутное окно; телефон,
// найдя компьютер в сети, показывает «Найден компьютер: <имя>.
// Подключиться?» и сохраняет адрес только после «Да». Без окна ожидания —
// телефон получает честное «ещё не готов», ничего не сохраняет молча.

const pairingWindow = 2 * time.Minute

type pairingState struct {
	mu        sync.Mutex
	until     time.Time
	confirmed int // растёт на каждое успешное подтверждение — окно ПК ловит рост, показывает «телефон подключился»
}

func (p *pairingState) open() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.until = time.Now().Add(pairingWindow)
}

func (p *pairingState) close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.until = time.Time{}
}

func (p *pairingState) status() (open bool, secondsLeft int, confirmed int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	left := time.Until(p.until)
	if left <= 0 {
		return false, 0, p.confirmed
	}
	return true, int(left.Seconds()) + 1, p.confirmed
}

// confirm — подтвердить, если окно ещё открыто; закрывает окно сразу после
// первого успешного подтверждения (обычный случай — один телефон).
func (p *pairingState) confirm() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if time.Until(p.until) <= 0 {
		return false
	}
	p.until = time.Time{}
	p.confirmed++
	return true
}

func hostLabel() string {
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return "SoundFlow"
}

// ---- ручки только с этого компьютера (окно) ----

func (s *Service) hPairingOpen(w http.ResponseWriter, r *http.Request) {
	s.pairing.open()
	_, left, _ := s.pairing.status()
	writeJSON(w, map[string]int{"seconds_left": left})
}

func (s *Service) hPairingClose(w http.ResponseWriter, r *http.Request) {
	s.pairing.close()
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Service) hPairingStatus(w http.ResponseWriter, r *http.Request) {
	open, left, confirmed := s.pairing.status()
	writeJSON(w, map[string]any{"open": open, "seconds_left": left, "confirmed": confirmed})
}

// ---- ручки для телефона (тот же /api/*, но без localOnly — их зовут по Wi-Fi) ----

func (s *Service) hPairingCheck(w http.ResponseWriter, r *http.Request) {
	open, _, _ := s.pairing.status()
	writeJSON(w, map[string]any{"open": open, "name": hostLabel()})
}

func (s *Service) hPairingConfirm(w http.ResponseWriter, r *http.Request) {
	if !s.pairing.confirm() {
		http.Error(w, "окно подключения закрыто — нажмите «Подключить телефон» на компьютере ещё раз", http.StatusConflict)
		return
	}
	_ = s.db.AddServerLog("info", "", "", "телефон подключился (первое подключение, подтверждено)", 0)
	resp := map[string]any{"ok": true, "name": hostLabel()}
	// Удалённый доступ через VDS (relay.go, Alex TG 24.09.2026) — если у
	// компьютера настроен канал, телефон узнаёт адрес и секретный ключ
	// сразу здесь, в момент, который Alex подтвердил своими руками, а не
	// вписывает их отдельно вручную. Не настроено — просто пустые поля,
	// телефон это уже умеет понимать (см. Api.pairingConfirm).
	if url := env("SOUNDFLOW_RELAY_PUBLIC_URL", ""); url != "" {
		if key := env("SOUNDFLOW_RELAY_SECRET", ""); key != "" {
			resp["relay_url"] = url
			resp["relay_key"] = key
		}
	}
	writeJSON(w, resp)
}
