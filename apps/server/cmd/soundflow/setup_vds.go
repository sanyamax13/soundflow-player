package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"soundflow/server/internal/appsettings"
)

// Шаг мастера «Свой ВДС» (часть 3 передачи плеера, 28.09.2026): доступ к музыке с телефона вне дома
// через ВДС человека — как у Alex (relay.go), только настраивается само. Программа создаёт свой
// SSH-ключ и секрет, показывает одну команду для консоли ВДС (build/vds-setup.sh: пользователь
// канала, nginx, бесплатный сертификат), затем по «Проверить» поднимает канал и стучится на свой же
// адрес снаружи.

// vdsScriptURL — где лежит скрипт настройки ВДС (канал обновлений Alex).
const vdsScriptURL = "https://vdsmusic.ru/soundflow/apk/vds-setup.sh"

var domainRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`)

// ensureRelayKey — SSH-ключ канала (relay_key рядом с базой): есть — берём, нет — создаём.
// Возвращает открытый ключ строкой «ssh-ed25519 AAAA…».
func ensureRelayKey(path string) (string, error) {
	if b, err := os.ReadFile(path); err == nil {
		signer, err := ssh.ParsePrivateKey(b)
		if err != nil {
			return "", fmt.Errorf("ключ канала повреждён: %w", err)
		}
		return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey()))), nil
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", err
	}
	block, err := ssh.MarshalPrivateKey(priv, "soundflow-relay")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, pem.EncodeToMemory(block), 0o600); err != nil {
		return "", err
	}
	sp, err := ssh.NewPublicKey(pub)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sp))), nil
}

// vdsDomain — адрес для телефона: свой домен или бесплатный <ip>.sslip.io (как в vds-setup.sh).
func vdsDomain(ip, domain string) string {
	if domain != "" {
		return domain
	}
	return strings.ReplaceAll(ip, ".", "-") + ".sslip.io"
}

// POST /api/setup/vds/prepare {"ip": "1.2.3.4", "domain": ""} — ключ, секрет, адрес; ответ — команда
// для консоли ВДС.
func (s *Service) hSetupVdsPrepare(w http.ResponseWriter, r *http.Request) {
	var in struct {
		IP     string `json:"ip"`
		Domain string `json:"domain"`
	}
	_ = json.NewDecoder(r.Body).Decode(&in)
	ip := strings.TrimSpace(in.IP)
	domain := strings.ToLower(strings.TrimSpace(in.Domain))
	if p := net.ParseIP(ip); p == nil || p.To4() == nil {
		http.Error(w, "Укажите адрес ВДС цифрами, например 185.10.20.30.", 400)
		return
	}
	if domain != "" && !domainRe.MatchString(domain) {
		http.Error(w, "Домен указан неверно. Если своего домена нет — оставьте поле пустым.", 400)
		return
	}
	dir := dataDir()
	keyPath := filepath.Join(dir, "relay_key")
	pub, err := ensureRelayKey(keyPath)
	if err != nil {
		http.Error(w, "Ключ канала не создан: "+err.Error(), 500)
		return
	}
	cur, _ := appsettings.Load(dir)
	secret := cur.Relay.Secret
	if secret == "" {
		secret = appsettings.RandomSecret(32)
	}
	// В окружение канал попадёт только по «Проверить» — до того ВДС ещё не настроен.
	st := cur
	st.Relay = appsettings.RelaySettings{
		Host: ip + ":22", User: "soundflow-relay", Secret: secret,
		PublicURL: "https://" + vdsDomain(ip, domain) + "/soundflow-remote", KeyFile: keyPath,
	}
	if err := appsettings.Save(dir, st); err != nil {
		http.Error(w, "Настройки не сохранились: "+err.Error(), 500)
		return
	}
	cmd := "curl -fsSL " + vdsScriptURL + " | sudo bash -s -- " + base64.StdEncoding.EncodeToString([]byte(pub))
	if domain != "" {
		cmd += " " + domain
	}
	writeJSON(w, map[string]string{"command": cmd, "url": st.Relay.PublicURL})
}

// POST /api/setup/vds/check — поднять канал и проверить адрес снаружи (до 40 с: SSH + сертификат).
func (s *Service) hSetupVdsCheck(w http.ResponseWriter, r *http.Request) {
	st, err := updateSettings(func(*appsettings.Settings) {})
	if err != nil || st.Relay.Host == "" {
		http.Error(w, "Сначала укажите адрес ВДС.", 400)
		return
	}
	s.restartRelay()
	cl := &http.Client{Timeout: 8 * time.Second}
	var last string
	for deadline := time.Now().Add(40 * time.Second); time.Now().Before(deadline); time.Sleep(3 * time.Second) {
		req, _ := http.NewRequestWithContext(r.Context(), "GET", st.Relay.PublicURL+"/v1/health", nil)
		req.Header.Set(relayKeyHeader, st.Relay.Secret)
		resp, err := cl.Do(req)
		if err != nil {
			last = err.Error()
			if r.Context().Err() != nil {
				return
			}
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == 200 {
			writeJSON(w, map[string]any{"ok": true, "url": st.Relay.PublicURL})
			return
		}
		last = resp.Status
	}
	msg := "ВДС не отвечает (" + last + "). Проверьте, что команда в консоли ВДС закончилась словом «ГОТОВО», и нажмите «Проверить» ещё раз."
	if strings.Contains(last, "502") {
		msg = "ВДС настроен, но канал до этого компьютера не поднялся. Проверьте адрес ВДС и нажмите «Проверить» ещё раз."
	}
	http.Error(w, msg, 502)
}
