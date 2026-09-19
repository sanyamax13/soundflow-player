package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"

	"soundflow/server/internal/api"
	"soundflow/server/internal/localdb"
	"soundflow/server/internal/pathmap"
)

// «Убрано на телефоне» (Alex TG 19943/19948, 19.09.2026): когда телефон
// передаёт, что песню убрали, программа НЕ стирает файл на компьютере сама, а
// показывает окно со списком; Alex нажимает одну кнопку — файлы стираются
// навсегда («как Shift+Delete»), без корзины. До нажатия файл лежит, но метка
// «больше не качать» уже стоит. Отдельного экрана «Убранные» нет: Alex попросил
// держать это скрытым, окно появляется, только когда есть что подтвердить.
//
// Причины «плохое качество»/«не та версия» сюда не попадают — для них сервер
// сам ищет замену (api.deleteAndReacquire).

// removalGate — шлюз для api.Server: вместо стирания ставит песню в ожидание.
type removalGate struct{ db *localdb.DB }

func (g removalGate) HoldErase(_ context.Context, h api.HeldErase) error {
	return g.db.AddPendingRemoval(localdb.PendingRemoval{
		TrackID:  h.TrackID,
		Artist:   h.Artist,
		Title:    h.Title,
		FilePath: h.Path,
		Bytes:    h.Bytes,
		Reason:   h.Reason,
	})
}

// GET /api/removals → {items:[…], count, bytes}
func (s *Service) hRemovals(w http.ResponseWriter, r *http.Request) {
	items, err := s.db.PendingRemovals()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	var total int64
	for _, p := range items {
		total += p.Bytes
	}
	writeJSON(w, map[string]any{"items": items, "count": len(items), "bytes": total})
}

// POST /api/removals/confirm  body {"ids":["t_…", …]}
//
// Стирает файлы ТОЛЬКО тех песен, что переданы (окно шлёт ровно то, что
// показало Alex — пришедшее за это время новое не стирается «втёмную»).
// Стирание насовсем (pathmap.DeleteForever, без корзины). Не вышло стереть
// файл — песня остаётся в ожидании, окно покажет её снова.
func (s *Service) hRemovalsConfirm(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "нужно тело {ids:[…]}", 400)
		return
	}
	res := s.eraseRemovals(body.IDs, s.pm)
	writeJSON(w, res)
}

type eraseResult struct {
	Erased     int   `json:"erased"`
	Failed     int   `json:"failed"`
	FreedBytes int64 `json:"freed_bytes"`
}

// eraseRemovals — сам разбор списка (отдельно от HTTP, чтобы проверять тестом).
func (s *Service) eraseRemovals(ids []string, pm pathmap.Mapper) eraseResult {
	var res eraseResult
	seen := map[string]bool{}
	for _, id := range ids {
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		p, ok, err := s.db.PendingRemoval(id)
		if err != nil {
			res.Failed++
			continue
		}
		if !ok {
			continue // уже разобрана
		}
		local := pm.ToLocal(p.FilePath)
		var size int64 // реальный размер на момент стирания; файла уже нет — 0
		if fi, e := os.Stat(local); e == nil {
			if fi.IsDir() { // защита: стираем только файлы
				res.Failed++
				continue
			}
			size = fi.Size()
		}
		if err := pathmap.DeleteForever(local); err != nil {
			res.Failed++
			_ = s.db.AddServerLog("error", p.Artist, p.Title, "не смог стереть файл: "+err.Error(), 0)
			continue
		}
		if err := s.db.DeletePendingRemoval(id); err != nil {
			// файл уже стёрт, а запись осталась: в следующий раз стирать нечего
			// (нет файла — не ошибка), запись уйдёт. Считаем стёртым.
			_ = s.db.AddServerLog("error", p.Artist, p.Title, "стёр файл, но не убрал из ожидания: "+err.Error(), 0)
		}
		_ = s.db.AddServerLog("removed", p.Artist, p.Title, "убран из плеера", size)
		res.Erased++
		res.FreedBytes += size
	}
	return res
}
