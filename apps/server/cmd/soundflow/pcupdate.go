package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Обновление программы на компьютере (передача плеера другому человеку, Alex 27.09.2026: «обновления
// должны приходить ему тоже, как и мне, но только с его условиями»). Канал тот же ВДС, что у кнопки
// «Обновить» на телефоне: pcVersionURL отдаёт {version, url, sha256, changelog}. В окне появляется
// кнопка «Обновить до …»; установщик запускается тихо и ставит поверх. Настройки человека
// (settings.json, база, ключ канала — %LocalAppData%\SoundFlow) установщик не трогает.

// appVersion — версия программы; задаётся при сборке: -ldflags "-X main.appVersion=0.2.0".
var appVersion = "dev"

const pcVersionURL = "https://vdsmusic.ru/soundflow/apk/pc-version.json"

type pcRelease struct {
	Version   string `json:"version"`
	URL       string `json:"url"`
	SHA256    string `json:"sha256"`
	Changelog string `json:"changelog"`
}

// newerVersion — a новее b («0.10.0» > «0.9.1»); сборка без версии ("dev") не обновляется.
func newerVersion(a, b string) bool {
	if b == "dev" || a == "" {
		return false
	}
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func fetchPCRelease(ctx context.Context) (pcRelease, error) {
	var rel pcRelease
	req, _ := http.NewRequestWithContext(ctx, "GET", pcVersionURL, nil)
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	if err != nil {
		return rel, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return rel, fmt.Errorf("канал обновлений: %s", resp.Status)
	}
	return rel, json.NewDecoder(resp.Body).Decode(&rel)
}

// GET /api/pc-update — есть ли новая версия.
func (s *Service) hPCUpdateCheck(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{"current": appVersion, "available": false}
	if rel, err := fetchPCRelease(r.Context()); err == nil {
		out["latest"] = rel.Version
		out["changelog"] = rel.Changelog
		out["available"] = newerVersion(rel.Version, appVersion)
	}
	writeJSON(w, out)
}

// POST /api/pc-update — скачать установщик, сверить контрольную сумму и запустить тихую установку.
// Установщик сам закрывает программу, ставит новую версию и запускает её снова.
func (s *Service) hPCUpdateInstall(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Minute)
	defer cancel()
	rel, err := fetchPCRelease(ctx)
	if err != nil || !newerVersion(rel.Version, appVersion) {
		http.Error(w, "Новой версии нет", 409)
		return
	}
	path := filepath.Join(os.TempDir(), "SoundFlow-Setup-"+rel.Version+".exe")
	if err := downloadChecked(ctx, rel.URL, rel.SHA256, path); err != nil {
		http.Error(w, "Обновление не скачалось: "+err.Error(), 502)
		return
	}
	cmd := exec.Command(path, "/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART")
	if err := cmd.Start(); err != nil {
		http.Error(w, "Установщик не запустился: "+err.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "", "обновление программы до "+rel.Version, 0)
	writeJSON(w, map[string]string{"version": rel.Version})
}

func downloadChecked(ctx context.Context, url, sum, path string) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s", resp.Status)
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	h := sha256.New()
	_, err = io.Copy(io.MultiWriter(f, h), resp.Body)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	if sum != "" && !strings.EqualFold(hex.EncodeToString(h.Sum(nil)), sum) {
		_ = os.Remove(path)
		return fmt.Errorf("файл повреждён при скачивании")
	}
	return nil
}
