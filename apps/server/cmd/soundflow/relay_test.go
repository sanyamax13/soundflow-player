package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"net/http"
	"net/http/httptest"
	"testing"

	"golang.org/x/crypto/ssh"
)

// Без секретного ключа в заголовке запрос через канал VDS даже не должен
// дойти до самого роутера — иначе кто угодно в интернете достучался бы до
// каталога Alex-а (Alex TG 24.09.2026, «секретный ключ, который будет
// знать только твой телефон и VDS»).
func TestRelayAuthRejectsWithoutKey(t *testing.T) {
	called := false
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true })
	h := relayAuth("верный-ключ", next)

	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/health", nil))

	if w.Code != http.StatusForbidden {
		t.Errorf("код ответа = %d, ждал 403", w.Code)
	}
	if called {
		t.Error("роутер вызван без ключа — не должен был")
	}
}

func TestRelayAuthRejectsWrongKey(t *testing.T) {
	called := false
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true })
	h := relayAuth("верный-ключ", next)

	req := httptest.NewRequest(http.MethodGet, "/v1/health", nil)
	req.Header.Set(relayKeyHeader, "чужой-ключ")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("код ответа = %d, ждал 403", w.Code)
	}
	if called {
		t.Error("роутер вызван с неверным ключом — не должен был")
	}
}

func TestRelayAuthPassesWithCorrectKey(t *testing.T) {
	called := false
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	})
	h := relayAuth("верный-ключ", next)

	req := httptest.NewRequest(http.MethodGet, "/v1/health", nil)
	req.Header.Set(relayKeyHeader, "верный-ключ")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("код ответа = %d, ждал 200", w.Code)
	}
	if !called {
		t.Error("роутер не вызван с верным ключом")
	}
}

func genSSHPubKey(t *testing.T) ssh.PublicKey {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sshPub, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return sshPub
}

// SOUNDFLOW_RELAY_HOST_KEY не задан — соединяемся без проверки отпечатка
// (не роняем канал из-за отсутствия настройки): колбэк принимает любой ключ,
// и pinned=false (relayOnce не должен сужать алгоритм ключа хоста).
func TestRelayHostKeyCallbackNoEnvAcceptsAnyKey(t *testing.T) {
	t.Setenv("SOUNDFLOW_RELAY_HOST_KEY", "")
	cb, pinned := relayHostKeyCallback()
	if pinned {
		t.Error("pinned должен быть false без настройки отпечатка")
	}
	if err := cb("host", nil, genSSHPubKey(t)); err != nil {
		t.Errorf("без настройки отпечатка колбэк должен пропускать любой ключ, получил: %v", err)
	}
}

// Задан отпечаток — колбэк должен реально сверять именно его, а не
// пропускать всё подряд (иначе секретный ключ в заголовке — единственная
// защита канала, а подмена сервера по пути осталась бы незамеченной).
func TestRelayHostKeyCallbackWithEnvRejectsWrongKey(t *testing.T) {
	real := genSSHPubKey(t)
	impostor := genSSHPubKey(t)
	knownHost := string(ssh.MarshalAuthorizedKey(real))
	t.Setenv("SOUNDFLOW_RELAY_HOST_KEY", knownHost)
	cb, pinned := relayHostKeyCallback()
	if !pinned {
		t.Error("pinned должен быть true с валидным отпечатком в env")
	}

	if err := cb("host", nil, impostor); err == nil {
		t.Error("колбэк принял чужой ключ хоста — должен был отклонить")
	}
	if err := cb("host", nil, real); err != nil {
		t.Errorf("колбэк отклонил свой же закреплённый ключ: %v", err)
	}
}

// Мусор вместо отпечатка в env не должен ронять программу — откатываемся
// на «без проверки», как при пустом env.
func TestRelayHostKeyCallbackGarbageEnvFallsBackToInsecure(t *testing.T) {
	t.Setenv("SOUNDFLOW_RELAY_HOST_KEY", "не-ssh-ключ-а-мусор")
	cb, pinned := relayHostKeyCallback()
	if pinned {
		t.Error("pinned должен быть false при кривом env")
	}
	if err := cb("host", nil, genSSHPubKey(t)); err != nil {
		t.Errorf("при кривом env колбэк должен откатиться на «без проверки», получил: %v", err)
	}
}
