package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// Пока окно не открыли — телефон честно видит «не готов», ничего скрытого
// не подключается (Alex TG 24.09.2026: раньше «Найти сервер самому» молча
// сохранял первый найденный адрес).
func TestPairingCheckClosedByDefault(t *testing.T) {
	e := ctxFixture(t)
	w := httptest.NewRecorder()
	e.s.hPairingCheck(w, httptest.NewRequest(http.MethodGet, "/api/pairing/check", nil))

	var out map[string]any
	if err := json.NewDecoder(w.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out["open"] != false {
		t.Errorf("окно должно быть закрыто по умолчанию, получили: %+v", out)
	}
}

// Открыли на компьютере -> телефон видит open:true и имя компьютера;
// подтвердил -> окно закрывается само, счётчик подтверждений растёт.
func TestPairingOpenThenConfirmCloses(t *testing.T) {
	e := ctxFixture(t)
	e.s.hPairingOpen(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/api/pairing/open", nil))

	w1 := httptest.NewRecorder()
	e.s.hPairingCheck(w1, httptest.NewRequest(http.MethodGet, "/api/pairing/check", nil))
	var check map[string]any
	if err := json.NewDecoder(w1.Body).Decode(&check); err != nil {
		t.Fatal(err)
	}
	if check["open"] != true {
		t.Fatalf("после «Подключить телефон» окно должно быть открыто: %+v", check)
	}
	if check["name"] == "" || check["name"] == nil {
		t.Errorf("имя компьютера должно быть непустым: %+v", check)
	}

	w2 := httptest.NewRecorder()
	e.s.hPairingConfirm(w2, httptest.NewRequest(http.MethodPost, "/api/pairing/confirm", nil))
	if w2.Code != http.StatusOK {
		t.Fatalf("первое подтверждение должно пройти, код %d: %s", w2.Code, w2.Body.String())
	}

	open, _, confirmed := e.s.pairing.status()
	if open {
		t.Error("после подтверждения окно должно закрыться само")
	}
	if confirmed != 1 {
		t.Errorf("ждали 1 подтверждение, получили %d", confirmed)
	}

	// Второй телефон в закрытое окно — уже нет.
	w3 := httptest.NewRecorder()
	e.s.hPairingConfirm(w3, httptest.NewRequest(http.MethodPost, "/api/pairing/confirm", nil))
	if w3.Code != http.StatusConflict {
		t.Errorf("подтверждение в закрытое окно должно быть отклонено, код %d", w3.Code)
	}
}

// Окно само истекает через 2 минуты без ручного закрытия.
func TestPairingWindowExpires(t *testing.T) {
	e := ctxFixture(t)
	e.s.pairing.until = time.Now().Add(-1 * time.Second) // как будто открыли и время вышло

	open, left, _ := e.s.pairing.status()
	if open || left != 0 {
		t.Errorf("истёкшее окно должно быть закрыто: open=%v left=%d", open, left)
	}

	w := httptest.NewRecorder()
	e.s.hPairingConfirm(w, httptest.NewRequest(http.MethodPost, "/api/pairing/confirm", nil))
	if w.Code != http.StatusConflict {
		t.Errorf("подтверждение после истечения должно быть отклонено, код %d", w.Code)
	}
}

// «Закрыть» с компьютера — телефон сразу видит closed, не дожидаясь 2 минут.
func TestPairingManualClose(t *testing.T) {
	e := ctxFixture(t)
	e.s.hPairingOpen(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/api/pairing/open", nil))
	e.s.hPairingClose(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/api/pairing/close", nil))

	open, _, _ := e.s.pairing.status()
	if open {
		t.Error("после ручного закрытия окно должно быть закрыто")
	}
}
