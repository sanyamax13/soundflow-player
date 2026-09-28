package main

import (
	"encoding/json"
	"net/http"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

// Последний шаг мастера — телефон (часть 4 передачи плеера, Alex 28.09.2026, вариант «А», без QR
// для подключения): мастер сам открывает «Подключить телефон», показывает ссылку на приложение
// (и QR с этой ссылкой — его читает обычная камера телефона, приложению сканер не нужен), дальше
// на телефоне «Найти компьютер».

// phoneVersionURL — канал обновлений приложения (тот же, что у кнопки «Обновить» на телефоне).
const phoneVersionURL = "https://vdsmusic.ru/soundflow/version"

// apkURL — ссылка на свежее приложение из канала обновлений; "" — канал не ответил.
func apkURL() string {
	cl := &http.Client{Timeout: 10 * time.Second}
	resp, err := cl.Get(phoneVersionURL)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	var v struct {
		ApkURL string `json:"apkUrl"`
	}
	if json.NewDecoder(resp.Body).Decode(&v) != nil {
		return ""
	}
	return v.ApkURL
}

// POST /api/setup/phone — открыть «Подключить телефон» и отдать ссылку на приложение.
func (s *Service) hSetupPhone(w http.ResponseWriter, r *http.Request) {
	s.pairing.open()
	_, _, confirmed := s.pairing.status()
	writeJSON(w, map[string]any{"apk": apkURL(), "confirmed": confirmed})
}

// GET /api/setup/apk-qr.png — QR со ссылкой на приложение.
func (s *Service) hSetupApkQR(w http.ResponseWriter, r *http.Request) {
	u := apkURL()
	if u == "" {
		http.Error(w, "канал обновлений не ответил", 502)
		return
	}
	png, err := qrcode.Encode(u, qrcode.Medium, 320)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	_, _ = w.Write(png)
}
