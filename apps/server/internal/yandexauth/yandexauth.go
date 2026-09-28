// Package yandexauth — вход в Яндекс Музыку «кодом на экране» (OAuth Device Flow,
// https://yandex.ru/dev/id/doc/ru/codes/screen-code-oauth): программа показывает короткий код, человек
// открывает ya.ru/device на любом устройстве, вводит код и подтверждает — программа получает токен.
// Пароль от Яндекса программа не видит. Нужен для мастера первого запуска своей копии плеера
// (28.09.2026): лайки и плейлисты человека — начальный вкус. Подписка не нужна.
package yandexauth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Публичные данные приложения Яндекс Музыки для Android — те же, что у библиотеки yandex-music
// (качалка работает с токеном, выданным именно им).
const (
	clientID     = "23cabbbdc6cd418abb4b39c32c41195d"
	clientSecret = "53bc75238f0c4d08a118e51fe9203300"
)

// BaseURL — адрес OAuth Яндекса (подменяется в тестах).
var BaseURL = "https://oauth.yandex.ru"

// ErrPending — человек ещё не ввёл код.
var ErrPending = errors.New("код ещё не подтверждён")

type Code struct {
	DeviceCode string `json:"device_code"`
	UserCode   string `json:"user_code"`
	URL        string `json:"verification_url"`
	Interval   int    `json:"interval"`
	ExpiresIn  int    `json:"expires_in"`
}

var client = &http.Client{Timeout: 20 * time.Second}

func post(ctx context.Context, path string, form url.Values, out any) error {
	req, err := http.NewRequestWithContext(ctx, "POST", BaseURL+path, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var raw map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return fmt.Errorf("ответ Яндекса не прочитан: %w", err)
	}
	if e, _ := raw["error"].(string); e != "" {
		if e == "authorization_pending" {
			return ErrPending
		}
		d, _ := raw["error_description"].(string)
		return fmt.Errorf("Яндекс: %s %s", e, d)
	}
	b, _ := json.Marshal(raw)
	return json.Unmarshal(b, out)
}

// Start — получить код для показа человеку.
func Start(ctx context.Context, deviceID, deviceName string) (Code, error) {
	var c Code
	err := post(ctx, "/device/code", url.Values{
		"client_id": {clientID}, "device_id": {deviceID}, "device_name": {deviceName},
	}, &c)
	if err == nil && (c.DeviceCode == "" || c.UserCode == "") {
		err = errors.New("Яндекс не выдал код")
	}
	if c.Interval < 5 {
		c.Interval = 5
	}
	return c, err
}

// Poll — один опрос: токен, ErrPending (ждём дальше) или ошибка (код истёк, отказ).
func Poll(ctx context.Context, deviceCode string) (string, error) {
	var t struct {
		AccessToken string `json:"access_token"`
	}
	err := post(ctx, "/token", url.Values{
		"grant_type": {"device_code"}, "code": {deviceCode},
		"client_id": {clientID}, "client_secret": {clientSecret},
	}, &t)
	if err != nil {
		return "", err
	}
	if t.AccessToken == "" {
		return "", errors.New("Яндекс не выдал токен")
	}
	return t.AccessToken, nil
}
