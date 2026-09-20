package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
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
//  4. файл переносится в <папка_базы>\_deleted (НЕ os.Remove — глобальное
//     правило: деструктив только с возможностью отката; папку Alex чистит сам).
//
// Фронт перед вызовом спрашивает подтверждение — отмена только вручную из
// _deleted.
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

	moved := ""
	copiesMoved := 0
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
		// 4. файл — в _deleted
		if m, e := s.moveToDeleted(s.localPath(canonical)); e != nil {
			_ = s.db.AddServerLog("error", artist, title, "не смог перенести файл в _deleted: "+e.Error(), 0)
		} else {
			moved = m
		}
		// 5. копии песни в других папках — туда же (Alex TG 20177, вариант 2)
		for _, cp := range s.findCopyFiles(ctx, map[string]string{normKey: s.localPath(canonical)})[normKey] {
			if m, e := s.moveToDeleted(cp); e != nil {
				_ = s.db.AddServerLog("error", artist, title, "не смог перенести копию в _deleted ("+cp+"): "+e.Error(), 0)
			} else if m != "" {
				copiesMoved++
			}
		}
	}

	_ = s.db.AddServerLog("info", artist, title, "удалён полностью из окна ПК (телефон+каталог+диск, помечен «не качать»)", 0)
	writeJSON(w, map[string]any{
		"deleted":      true,
		"in_catalog":   ok,
		"file_moved":   moved != "",
		"copies_moved": copiesMoved,
		"trash":        moved,
		"blocked_key":  normKey,
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

// moveToDeleted — перенести файл в <папка_базы>\_deleted с датой в имени.
// Пустой путь / нет файла — не ошибка (вернёт ""). Другой том — копия + удаление.
func (s *Service) moveToDeleted(local string) (string, error) {
	if local == "" {
		return "", nil
	}
	if _, err := os.Stat(local); err != nil {
		return "", nil // файла уже нет
	}
	dir := filepath.Join(filepath.Dir(s.dbPath), "_deleted")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	dst := filepath.Join(dir, time.Now().Format("20060102-150405")+"__"+filepath.Base(local))
	if _, err := os.Stat(dst); err == nil { // копии одной песни часто зовутся одинаково — ничего не затираем
		dst = strings.TrimSuffix(dst, filepath.Ext(dst)) + "__" + fmt.Sprint(time.Now().UnixNano()) + filepath.Ext(dst)
	}
	if err := os.Rename(local, dst); err == nil {
		return dst, nil
	}
	// другой том — копируем и удаляем исходник
	if err := copyFile(local, dst); err != nil {
		return "", err
	}
	if err := os.Remove(local); err != nil {
		return dst, err
	}
	return dst, nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
