package main

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"
)

// «Ручная синхронизация телефона» (Alex TG 19000, 19002): комп считает
// разницу каталог ↔ телефон и показывает список ПЕРЕД закачкой. Окно
// (frontend) рисует: «добавить», «удалить», «уже на телефоне» (серым,
// Alex 08.09.2026 — чтобы видел, что дубликатов не будет) и «предлагаю по
// вкусу» (из /api/devices/{id}/suggest). «Далее» → hSyncPlanCommit.

type syncItem struct {
	ID        string `json:"id"`
	Artist    string `json:"artist"`
	Title     string `json:"title"`
	SizeBytes int64  `json:"size_bytes"`
}

type syncPreview struct {
	DeviceID   string     `json:"device_id"`
	Add        []syncItem `json:"add"`       // есть в каталоге, нет на телефоне
	Remove     []syncItem `json:"remove"`    // есть на телефоне, нет в каталоге
	OnDevice   []syncItem `json:"on_device"` // уже на телефоне — окно рисует серым
	AddBytes   int64      `json:"add_bytes"`
	HaveCount  int        `json:"have_count"`
	CatalogCnt int        `json:"catalog_count"`
}

// GET /api/devices/{id}/sync-preview
func (s *Service) hSyncPreview(w http.ResponseWriter, r *http.Request) {
	dev := chi.URLParam(r, "id")
	if dev == "" {
		http.Error(w, "нужен id устройства", 400)
		return
	}
	have, err := s.db.DeviceTrackIDs(dev)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	cat, err := s.db.CatalogList(1 << 30) // весь каталог (CatalogList всегда с LIMIT)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	inCatalog := make(map[string]localdbCat, len(cat))
	out := syncPreview{DeviceID: dev, HaveCount: len(have), CatalogCnt: len(cat)}
	for _, t := range cat {
		inCatalog[t.ID] = localdbCat{t.Artist, t.Title, t.SizeBytes}
		if have[t.ID] {
			out.OnDevice = append(out.OnDevice, syncItem{t.ID, t.Artist, t.Title, t.SizeBytes})
		} else {
			out.Add = append(out.Add, syncItem{t.ID, t.Artist, t.Title, t.SizeBytes})
			out.AddBytes += t.SizeBytes
		}
	}
	for id := range have {
		if _, ok := inCatalog[id]; !ok {
			out.Remove = append(out.Remove, syncItem{ID: id, Title: "(нет в каталоге)"})
		}
	}
	writeJSON(w, out)
}

type localdbCat struct {
	artist string
	title  string
	size   int64
}

// POST /api/devices/{id}/sync-plan  body {"add":[ids],"remove":[ids]}
// Окно сохраняет выбор Alex; телефон заберёт при подключении.
func (s *Service) hSyncPlanCommit(w http.ResponseWriter, r *http.Request) {
	dev := chi.URLParam(r, "id")
	var body struct {
		Add    []string `json:"add"`
		Remove []string `json:"remove"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || dev == "" {
		http.Error(w, "нужен id и тело {add,remove}", 400)
		return
	}
	if err := s.db.SavePlan(dev, body.Add, body.Remove); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "", "план синхронизации сохранён: +"+strconv.Itoa(len(body.Add))+" −"+strconv.Itoa(len(body.Remove)), 0)
	writeJSON(w, map[string]any{"saved": true, "add": len(body.Add), "remove": len(body.Remove)})
}

