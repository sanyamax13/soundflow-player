package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sort"
	"time"

	"soundflow/server/internal/localdb"
)

// Сверка телефона с компьютером (Alex TG 20277–20279, 21.09.2026): «постоянный инструмент, чтобы сверять базу телефона и
// компьютера, точное количество», «окно: на телефоне столько-то песен, на компьютере столько-то, базы ровные; если не
// ровно — нажимаешь, и он выравнивает, приоритет компьютер».
//
// Телефон сам присылает точный список своих песен (POST /api/phone/inventory, id и размер; раньше компьютер знал состав
// только по журналу событий — приблизительно). Компьютер сравнивает со своими песнями (файл на диске есть) и показывает в
// окне: сколько там и там, сколько только на телефоне, сколько только на компьютере. «Выровнять» кладёт в план телефона:
// убрать то, чего нет у компьютера, и добавить то, чего нет у телефона — дальше это привычная карточка «Скачать / Стереть» на
// телефоне (Alex TG 20167: решает он, места на телефоне может не хватить). Стирание на телефоне необратимо (у песни, которой
// нет у компьютера, других копий нет), поэтому:
//   - «Выровнять» — только с этого компьютера, список для плана сервер собирает заново сам, а не берёт из окна;
//   - только по точному и свежему списку телефона (не старше phoneListFresh), не по журналу;
//   - пока идёт возврат песен с телефона на компьютер (restore.go), выравнивать нельзя;
//   - если диск с музыкой недоступен, песни с него считаются «есть на компьютере» — отключённый диск не превращает
//     весь телефон в «лишнее»;
//   - что Alex сам убрал с телефона из окна, обратно не добавляется; «не качать» не добавляется;
//   - план дополняется, а не затирается (MergePlan).
const (
	phoneListFresh = 12 * time.Hour
	pcSongsTTL     = 20 * time.Second
)

type phoneCheck struct {
	HasPhone       bool   `json:"has_phone"`
	Device         string `json:"device"`
	Exact          bool   `json:"exact"` // состав телефона прислал сам телефон (иначе — по журналу событий, приблизительно)
	At             string `json:"at"`    // когда телефон прислал список
	Stale          bool   `json:"stale"` // список старше phoneListFresh
	Phone          int    `json:"phone"`
	PhoneBytes     int64  `json:"phone_bytes"`
	PC             int    `json:"pc"`
	PCBytes        int64  `json:"pc_bytes"`
	Both           int    `json:"both"`
	OnlyPhone      int    `json:"only_phone"` // на телефоне есть, у компьютера нет — «Выровнять» предложит стереть
	OnlyPhoneBytes int64  `json:"only_phone_bytes"`
	OnlyPC         int    `json:"only_pc"` // у компьютера есть, на телефоне нет — «Выровнять» предложит добавить
	OnlyPCBytes    int64  `json:"only_pc_bytes"`
	Removed        int    `json:"removed"`   // у компьютера есть, но Alex сам убрал с телефона — не добавляем
	Arriving       int    `json:"arriving"`  // на телефоне есть и едут на компьютер (возврат)
	Restoring      int    `json:"restoring"` // сколько песен всего ещё ждут возврата на компьютер
	Even           bool   `json:"even"`
	CanAlign       bool   `json:"can_align"`
	Why            string `json:"why,omitempty"` // почему выровнять сейчас нельзя
}

// pcSongs — песни компьютера с файлом на диске: id → размер. Песня, чей диск/папка музыки недоступны, считается
// «есть» (по записанному размеру): за недоступное не решаем, как и сверка каталога с диском.
func (s *Service) pcSongs(fresh bool) (map[string]int64, error) {
	s.pcMu.Lock()
	defer s.pcMu.Unlock()
	if !fresh && s.pcSet != nil && time.Since(s.pcAt) < pcSongsTTL {
		return s.pcSet, nil
	}
	refs, err := s.db.PCSyncFiles()
	if err != nil {
		return nil, err
	}
	set := make(map[string]int64, len(refs))
	rootOK := map[string]bool{}
	for _, r := range refs {
		if r.TrackID == "" {
			continue
		}
		if _, have := set[r.TrackID]; have {
			continue
		}
		local := s.localPath(r.Path)
		root := pathRoot(local)
		ok, seen := rootOK[root]
		if !seen {
			fi, err := os.Stat(root)
			ok = err == nil && fi.IsDir()
			rootOK[root] = ok
		}
		if !ok {
			set[r.TrackID] = r.Size
			continue
		}
		if fi, err := os.Stat(local); err == nil && !fi.IsDir() {
			set[r.TrackID] = fi.Size()
		}
	}
	s.pcSet, s.pcAt = set, time.Now()
	return set, nil
}

// comparePhone — сравнение «живого» телефона (заходил последним) с компьютером и списки для плана выравнивания.
func (s *Service) comparePhone(fresh bool) (chk phoneCheck, dev string, add, remove []string, err error) {
	dev, name, _, ok, err := s.db.LatestDevice()
	if err != nil || !ok {
		chk.Why = "телефон ещё ни разу не заходил"
		return chk, "", nil, nil, err
	}
	chk.HasPhone, chk.Device = true, name
	phone := map[string]int64{}
	inv, at, exact, err := s.db.PhoneInventory(dev)
	if err != nil {
		return chk, dev, nil, nil, err
	}
	if exact {
		phone, chk.Exact, chk.At = inv, true, at
		if t, e := time.Parse(time.RFC3339, at); e != nil || time.Since(t) > phoneListFresh {
			chk.Stale = true
		}
	} else {
		have, err := s.db.DeviceTrackIDs(dev)
		if err != nil {
			return chk, dev, nil, nil, err
		}
		for id := range have {
			phone[id] = 0
		}
	}
	mine, err := s.pcSongs(fresh)
	if err != nil {
		return chk, dev, nil, nil, err
	}
	wanted, err := s.db.RestoreWantedIDs()
	if err != nil {
		return chk, dev, nil, nil, err
	}
	removed, err := s.db.PCRemovedIDs()
	if err != nil {
		return chk, dev, nil, nil, err
	}
	chk.Restoring = len(wanted)
	for id, size := range phone {
		chk.Phone++
		chk.PhoneBytes += size
		switch {
		case songIn(mine, id):
			chk.Both++
		case wanted[id]:
			chk.Arriving++
		default:
			chk.OnlyPhone++
			chk.OnlyPhoneBytes += size
			remove = append(remove, id)
		}
	}
	for id, size := range mine {
		chk.PC++
		chk.PCBytes += size
		if _, on := phone[id]; on {
			continue
		}
		if removed[id] {
			chk.Removed++
			continue
		}
		chk.OnlyPC++
		chk.OnlyPCBytes += size
		add = append(add, id)
	}
	sort.Strings(add)
	sort.Strings(remove)
	chk.Even = chk.OnlyPhone == 0 && chk.OnlyPC == 0 && chk.Arriving == 0
	switch {
	case chk.Restoring > 0:
		chk.Why = fmt.Sprintf("ещё едут песни с телефона на компьютер (%d) — выровнять можно, когда они вернутся", chk.Restoring)
	case !chk.Exact:
		chk.Why = "телефон ещё не присылал точный список — открой приложение на телефоне (версия 69 и новее)"
	case chk.Stale:
		chk.Why = "список телефона устарел — открой приложение на телефоне, оно пришлёт свежий"
	case chk.Even:
		chk.Why = "уже ровно"
	}
	chk.CanAlign = chk.Why == ""
	return chk, dev, add, remove, nil
}

func songIn(m map[string]int64, id string) bool {
	_, ok := m[id]
	return ok
}

// POST /api/phone/inventory {"device_id":"…","items":[{"id":"…","b":123}]} — телефон присылает точный список своих песен.
func (s *Service) hPhoneInventory(w http.ResponseWriter, r *http.Request) {
	var body struct {
		DeviceID string                  `json:"device_id"`
		Items    []localdb.InventoryItem `json:"items"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<20)).Decode(&body); err != nil || body.DeviceID == "" {
		http.Error(w, "нужно тело {device_id, items:[{id,b}]}", 400)
		return
	}
	known, err := s.db.DeviceExists(body.DeviceID)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if !known {
		http.Error(w, "такого устройства нет — сначала обычная синхронизация", http.StatusConflict)
		return
	}
	if err := s.db.SavePhoneInventory(body.DeviceID, body.Items); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]any{"saved": len(body.Items)})
}

// GET /api/phone/check — числа для окна: сколько на телефоне, сколько на компьютере, что расходится.
func (s *Service) hPhoneCheck(w http.ResponseWriter, r *http.Request) {
	chk, _, _, _, err := s.comparePhone(false)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, chk)
}

// POST /api/phone/align — «только с этого компьютера»: выровнять телефон по компьютеру. Список сервер собирает заново,
// кладёт в план телефона (дополняя), дальше телефон предлагает «Скачать / Стереть».
func (s *Service) hPhoneAlign(w http.ResponseWriter, r *http.Request) {
	chk, dev, add, remove, err := s.comparePhone(true)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if !chk.CanAlign {
		http.Error(w, chk.Why, http.StatusConflict)
		return
	}
	nAdd, nRemove, err := s.db.MergePlan(dev, add, remove)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "", fmt.Sprintf(
		"сверка телефона с компьютером: в план телефона +%d (%d МБ) −%d (%d МБ), всего в плане +%d −%d",
		len(add), chk.OnlyPCBytes>>20, len(remove), chk.OnlyPhoneBytes>>20, nAdd, nRemove), 0)
	writeJSON(w, map[string]any{"add": len(add), "add_bytes": chk.OnlyPCBytes, "remove": len(remove), "remove_bytes": chk.OnlyPhoneBytes,
		"plan_add": nAdd, "plan_remove": nRemove})
}
