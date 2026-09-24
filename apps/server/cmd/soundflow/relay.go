package main

import (
	"net/http"
	"os"
	"time"

	"golang.org/x/crypto/ssh"
)

// Удалённый доступ через VDS (Alex TG 24.09.2026, вместо Tailscale — см.
// docs/TAILSCALE-REMOTE-ACCESS-PLAN.md, раздел «Варианты после находки о
// Windows»). Tailscale (компания) блокирует свои сервера для российских
// IP с конца 2024 (санкции) — вместо отдельной VPN-сети программа сама
// держит постоянный SSH-канал до VDS Alex-а: ssh у этого VDS работает
// надёжно даже в те моменты, когда обычный HTTPS/443 иногда рвётся из РФ
// (замечено ранее при публикации канала обновлений). VDS слушает
// пробрасываемый порт локально (127.0.0.1) и отдаёт его наружу через
// nginx — телефон обращается к обычному https-адресу VDS, как раньше к
// домашнему Wi-Fi, просто с секретным ключом в заголовке (relayAuth
// ниже) — иначе кто угодно в интернете достучался бы до каталога.
//
// Без настройки (SOUNDFLOW_RELAY_HOST пуст) — тихо выключено, как
// качалка/модель.

const (
	relayReconnectDelay = 10 * time.Second
	relayDialTimeout    = 15 * time.Second
	relayKeyHeader      = "X-Soundflow-Relay-Key"
)

func (s *Service) startRelay() {
	host := env("SOUNDFLOW_RELAY_HOST", "")              // "72.4.69.204:22"
	user := env("SOUNDFLOW_RELAY_USER", "")              // "soundflow-relay"
	keyPath := env("SOUNDFLOW_RELAY_KEY_FILE", "")       // путь к приватному ключу
	remoteBind := env("SOUNDFLOW_RELAY_REMOTE_BIND", "") // "127.0.0.1:8093" на VDS
	secret := env("SOUNDFLOW_RELAY_SECRET", "")
	if host == "" || user == "" || keyPath == "" || remoteBind == "" || secret == "" {
		return // не настроено — тихо выключено, как качалка/модель
	}
	handler := relayAuth(secret, s.buildPhoneRouter())
	srv := &http.Server{Handler: handler}
	s.relaySrv = srv
	go s.relayLoop(host, user, keyPath, remoteBind, srv)
}

func (s *Service) relayLoop(host, user, keyPath, remoteBind string, srv *http.Server) {
	for !s.relayStop.Load() {
		if err := s.relayOnce(host, user, keyPath, remoteBind, srv); err != nil {
			_ = s.db.AddServerLog("error", "", "", "канал до VDS оборвался: "+err.Error(), 0)
		}
		if s.relayStop.Load() {
			return
		}
		time.Sleep(relayReconnectDelay)
	}
}

// relayOnce — один цикл жизни соединения: поднять SSH, попросить сервер
// слушать remoteBind у себя, отдавать через него buildPhoneRouter, пока
// соединение живо. Возвращается (с ошибкой), когда канал оборвался —
// relayLoop заново наберёт после паузы.
func (s *Service) relayOnce(host, user, keyPath, remoteBind string, srv *http.Server) error {
	keyBytes, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}
	signer, err := ssh.ParsePrivateKey(keyBytes)
	if err != nil {
		return err
	}
	hostKeyCallback, pinned := relayHostKeyCallback()
	cfg := &ssh.ClientConfig{
		User: user,
		Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)},
		// Отпечаток VDS закрепляется отдельно (SOUNDFLOW_RELAY_HOST_KEY) —
		// без него по умолчанию просто соединяемся: сам SSH-канал видит
		// содержимое каталога Alex-а, но не пароли/деньги, а адрес VDS
		// свой собственный, известный заранее.
		HostKeyCallback: hostKeyCallback,
		Timeout:         relayDialTimeout,
	}
	if pinned {
		// Сервер отдаёт несколько типов ключа хоста (rsa/ecdsa/ed25519) —
		// без этого клиент мог договориться не на тот тип, и FixedHostKey
		// честно отверг бы соединение как «host key mismatch», хотя VDS
		// настоящий (поймано вживую 24.09.2026 при первом подключении).
		cfg.HostKeyAlgorithms = []string{ssh.KeyAlgoED25519}
	}
	client, err := ssh.Dial("tcp", host, cfg)
	if err != nil {
		return err
	}
	defer client.Close()

	ln, err := client.Listen("tcp", remoteBind)
	if err != nil {
		return err
	}
	defer ln.Close()

	_ = s.db.AddServerLog("info", "", "", "канал до VDS поднят ("+remoteBind+")", 0)
	err = srv.Serve(ln)
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}

func (s *Service) stopRelay() {
	s.relayStop.Store(true)
	if s.relaySrv != nil {
		_ = s.relaySrv.Close()
	}
}

// relayHostKeyCallback — SOUNDFLOW_RELAY_HOST_KEY (отпечаток вида
// "ssh-ed25519 AAAA...", как в ~/.ssh/known_hosts) закрепляет ИМЕННО этот
// VDS; не задан — соединяемся без проверки (сам VDS известен заранее,
// адрес не случайный, но проверку лучше включить при настройке). Второе
// значение — закреплён ли отпечаток; relayOnce использует его, чтобы
// заставить клиента запросить у сервера именно ed25519-ключ хоста (сервер
// отдаёт rsa/ecdsa/ed25519 — без этого можно было бы получить не тот тип
// и FixedHostKey честно, но неверно отверг бы соединение).
func relayHostKeyCallback() (cb ssh.HostKeyCallback, pinned bool) {
	raw := env("SOUNDFLOW_RELAY_HOST_KEY", "")
	if raw == "" {
		return ssh.InsecureIgnoreHostKey(), false //nolint:gosec // см. комментарий выше
	}
	pub, _, _, _, err := ssh.ParseAuthorizedKey([]byte(raw))
	if err != nil {
		return ssh.InsecureIgnoreHostKey(), false //nolint:gosec // отпечаток не разобрался — не роняем канал
	}
	return ssh.FixedHostKey(pub), true
}

// relayAuth — секретный ключ в заголовке (см. комментарий вверху файла):
// без него запрос через канал VDS даже не доходит до самого роутера.
func relayAuth(secret string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get(relayKeyHeader) != secret {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}
