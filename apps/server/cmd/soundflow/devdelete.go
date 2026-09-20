package main

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"soundflow/server/internal/db"
)

// POST /api/devices/{id}/track/delete   body {"track_id":"..."}
//
// «Удалить полностью» из карточки телефона в окне ПК (Alex TG 19160: «полностью
// удаляет и с телефона, и с каталога, и с диска, и помечает, чтобы такое больше
// не качать»). Одно действие делает всё сразу:
//
//  1. трек добавляется в план синхронизации на удаление → телефон сотрёт свою
//     копию при следующем подключении (существующий план не затираем — только
//     дополняем);
//  2. строка трека убирается из каталога ПК (DeleteTrackByKey — каскадом и
//     track_files);
//  3. normalized_key помечается blocked в legacy_marks → «Найти трек»/догон
//     больше его не скачают;
//  4. файл (и копии песни в других папках) стираются с диска насовсем — Alex TG 20196/20198,
//     20.09.2026: «стирать, папку _deleted тоже удаляй», «удаляй всё, возвращать не надо»
//     (раньше файл уезжал в <папка_базы>\_deleted, и Alex чистил её сам).
//
// Фронт перед вызовом спрашивает подтверждение; вернуть стёртое нельзя.
func (s *Service) hDevTrackDelete(w http.ResponseWriter, r *http.Request) {
	dev := chi.URLParam(r, "id")
	var body struct {
		TrackID string `json:"track_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || dev == "" || body.TrackID == "" {
		http.Error(w, "нужен id устройства и track_id", 400)
		return
	}
	if s.store == nil {
		http.Error(w, "сервис ещё поднимается, попробуй через пару секунд", 503)
		return
	}
	ctx := r.Context()
	id := body.TrackID

	normKey, canonical, ok, err := s.store.TrackForDeletion(ctx, id)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	artist, title, _, _ := s.store.TrackArtistTitle(ctx, id)

	// 1. в план телефона на удаление — дополняем, не затираем
	if err := s.planAddRemove(dev, id); err != nil {
		http.Error(w, "план синхронизации: "+err.Error(), 500)
		return
	}

	fileErased := false
	copiesErased := 0
	if ok {
		// 2. из каталога ПК
		if err := s.store.DeleteTrackByKey(ctx, normKey); err != nil {
			http.Error(w, "убрать из каталога: "+err.Error(), 500)
			return
		}
		// 3. «больше не качать»
		_ = s.store.UpsertLegacyMark(ctx, db.LegacyMark{
			Key: normKey, Kind: "blocked", Artist: artist, Title: title, At: time.Now(),
		})
		// 4. файл — стереть насовсем
		if _, erased, e := eraseFile(s.localPath(canonical)); e != nil {
			_ = s.db.AddServerLog("error", artist, title, "не смог стереть файл: "+e.Error(), 0)
		} else {
			fileErased = erased
		}
		// 5. копии песни в других папках — так же (Alex TG 20177, вариант 2)
		for _, cp := range s.findCopyFiles(ctx, map[string]string{normKey: s.localPath(canonical)})[normKey] {
			if _, erased, e := eraseFile(cp); e != nil {
				_ = s.db.AddServerLog("error", artist, title, "не смог стереть копию ("+cp+"): "+e.Error(), 0)
			} else if erased {
				copiesErased++
			}
		}
	}

	_ = s.db.AddServerLog("info", artist, title, "удалён полностью из окна ПК (телефон+каталог+диск, помечен «не качать»)", 0)
	writeJSON(w, map[string]any{
		"deleted":       true,
		"in_catalog":    ok,
		"file_erased":   fileErased,
		"copies_erased": copiesErased,
		"blocked_key":   normKey,
	})
}

// planAddRemove — добавить trackID в remove-список активного плана устройства,
// не трогая остальное. Если трек был в add — убираем его оттуда.
func (s *Service) planAddRemove(dev, trackID string) error {
	add, remove, _, _, err := s.db.Plan(dev)
	if err != nil {
		return err
	}
	newAdd := add[:0]
	for _, x := range add {
		if x != trackID {
			newAdd = append(newAdd, x)
		}
	}
	for _, x := range remove {
		if x == trackID {
			return s.db.SavePlan(dev, newAdd, remove) // уже есть — просто сохраним подчищенный add
		}
	}
	return s.db.SavePlan(dev, newAdd, append(remove, trackID))
}
