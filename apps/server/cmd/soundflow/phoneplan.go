package main

import (
	"fmt"
	"net/http"
	"strconv"
	"time"
)

// План телефона «человеческим языком» — основа кнопки «Обновить телефон» и экрана «Активность» (ревизия 20.09.2026,
// `docs/revision-2026-09-20/05-one-press.md`, шаг 4, пункты С1 и С2). Раньше /api/phone/state отдавал плану только голые
// id, отменить его с компьютера было нельзя — без этого не написать «+12 песен, −3, 0,8 ГБ» и не сделать «Вернуть».

const planListLimit = 200 // сколько песен каждого списка отдаём поимённо; счётчики и байты — по ВСЕМУ плану

// planItem — песня плана. Убранная из каталога после того, как попала в план, приходит без названия (Missing).
type planItem struct {
	ID        string `json:"id"`
	Artist    string `json:"artist"`
	Title     string `json:"title"`
	SizeBytes int64  `json:"size_bytes"`
	Missing   bool   `json:"missing,omitempty"` // песни уже нет в каталоге (или она в «не качать») — телефон её не скачает
}

type planResp struct {
	DeviceID    string     `json:"device_id"`
	Device      string     `json:"device"`
	HasPlan     bool       `json:"has_plan"`
	At          string     `json:"at,omitempty"` // когда план положили (RFC3339)
	Add         []planItem `json:"add"`          // первые planListLimit песен «скачать»
	Remove      []planItem `json:"remove"`       // первые planListLimit песен «стереть с телефона»
	AddCount    int        `json:"add_count"`    // ВСЕГО в плане (а не длина списка выше)
	RemoveCount int        `json:"remove_count"`
	AddBytes    int64      `json:"add_bytes"`    // сколько скачает телефон (по всему списку, только песни из каталога)
	RemoveBytes int64      `json:"remove_bytes"` // сколько освободится (по всему списку, где размер известен)
	MissingAdd  int        `json:"missing_add"`  // из «скачать» песен, которых уже нет в каталоге: телефон их пропустит
	Truncated   bool       `json:"truncated"`    // списки Add/Remove обрезаны до planListLimit
}

// GET /api/phone/plan?limit=N — что сейчас лежит в плане «живого» телефона: названия и объём. Телефон заберёт план
// при следующем заходе; пока не забрал — план можно посмотреть здесь и отменить (DELETE).
func (s *Service) hPhonePlanGet(w http.ResponseWriter, r *http.Request) {
	limit := planListLimit
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v >= 0 && v <= 5000 {
		limit = v
	}
	out := planResp{Add: []planItem{}, Remove: []planItem{}}
	id, name, _, ok, err := s.db.LatestDevice()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if !ok {
		writeJSON(w, out)
		return
	}
	out.DeviceID, out.Device = id, name
	addIDs, removeIDs, at, has, err := s.db.Plan(id)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if !has || (len(addIDs) == 0 && len(removeIDs) == 0) {
		writeJSON(w, out)
		return
	}
	out.HasPlan, out.At = true, at
	out.AddCount, out.RemoveCount = len(addIDs), len(removeIDs)

	// карточки нужны по ВСЕМУ плану (байты и «нет в каталоге»), а поимённо отдаём только начало
	cards := map[string]planItem{}
	all := append(append([]string{}, addIDs...), removeIDs...)
	list, err := s.db.TracksByIDs(all)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	for _, c := range list {
		cards[c.ID] = planItem{ID: c.ID, Artist: c.Artist, Title: c.Title, SizeBytes: c.SizeBytes}
	}
	fill := func(ids []string) (items []planItem, bytes int64, missing int) {
		items = []planItem{}
		for i, tid := range ids {
			it, found := cards[tid]
			if !found {
				it = planItem{ID: tid, Missing: true}
				missing++
			}
			bytes += it.SizeBytes
			if i < limit {
				items = append(items, it)
			}
		}
		return items, bytes, missing
	}
	out.Add, out.AddBytes, out.MissingAdd = fill(addIDs)
	out.Remove, out.RemoveBytes, _ = fill(removeIDs)
	out.Truncated = out.AddCount > limit || out.RemoveCount > limit
	writeJSON(w, out)
}

// DELETE /api/phone/plan — отменить план «живого» телефона целиком («Вернуть»). Ничего не стирает и не пишет «убрано с
// телефона»: план просто снимается, песни на телефоне остаются как были. Телефон, который план уже забрал и выполняет,
// остановить нельзя — отвечаем «плана уже нет» (cancelled=false), окно тогда так и пишет.
func (s *Service) hPhonePlanCancel(w http.ResponseWriter, r *http.Request) {
	id, name, _, ok, err := s.db.LatestDevice()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if !ok {
		http.Error(w, "телефон ещё ни разу не заходил — отменять нечего", http.StatusConflict)
		return
	}
	add, remove, _, _, _ := s.db.Plan(id)
	had, err := s.db.DiscardPlan(id)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if had {
		_ = s.db.AddServerLog("info", "", "", fmt.Sprintf("план телефона отменён из окна (было +%d −%d)", len(add), len(remove)), 0)
	}
	writeJSON(w, map[string]any{"cancelled": had, "device": name, "was_add": len(add), "was_remove": len(remove),
		"at": time.Now().UTC().Format(time.RFC3339)})
}
