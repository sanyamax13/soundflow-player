package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/go-chi/chi/v5"

	"soundflow/server/internal/localdb"
)

// Возврат песен с телефона на компьютер (Alex TG 20261–20267, 21.09.2026): Alex стёр с компьютера ~7 200 песен
// (папки-сборники), а часть из них осталась на телефоне — «может скопируешь их с телефона сам сейчас?». Разово и без
// кнопок (Alex: «не надо кнопок … не нужно на постоянку»): программа записывает, какие песни ждут файл с телефона,
// телефон при следующем обновлении сам, тихо, по домашней сети отдаёт их файлы — каждый на ПРЕЖНЕЕ место
// (запись каталога снова сходится с файлом, лайки и метки остаются, двойников нет).
//
// Защита:
//   - принимаем файл только для песни из списка «ждём» и только на её прежний путь (путь берём из базы, не из запроса);
//   - существующий файл не перезаписываем;
//   - пишем во временный файл рядом (расширение не аудио — скан его не видит) и переименовываем, когда всё принято;
//   - принятое проверяем: расширение аудио, начало файла похоже на этот формат, размер не меньше 90 % прежнего;
//   - корень пути (диск и первая папка, G:\музыка) должен существовать — как у сверки каталога с диском;
//   - пока песня «ждёт» файл, сверка каталога не считает её пропавшей и не убирает из каталога (findMissing).
const (
	restoreMaxBytes  = 600 << 20
	restoreTmpSuffix = ".sf-restore.part"
)

// одна отдача файла за раз: телефон шлёт по очереди, а два запроса на одну песню не должны писать в один временный файл
var restoreMu sync.Mutex

// looksLikeAudio — начало файла (первые байты) похоже на формат по расширению; проверка от мусора и обрезков, не полный разбор.
func looksLikeAudio(ext string, head []byte) bool {
	has := func(off int, s string) bool { return len(head) >= off+len(s) && string(head[off:off+len(s)]) == s }
	switch ext {
	case ".mp3", ".aac":
		return has(0, "ID3") || (len(head) >= 2 && head[0] == 0xFF && head[1]&0xE0 == 0xE0)
	case ".flac":
		return has(0, "fLaC") || has(0, "ID3")
	case ".m4a":
		return has(4, "ftyp")
	case ".ogg", ".opus":
		return has(0, "OggS")
	case ".wav":
		return has(0, "RIFF")
	case ".wma":
		return bytes.HasPrefix(head, []byte{0x30, 0x26, 0xB2, 0x75})
	}
	return false
}

// backupFile — путь к копии базы из папки _backup рядом с базой (та, что программа сама делает перед уборкой), с проверкой.
func (s *Service) backupFile(p string) (string, error) {
	p = filepath.Clean(p)
	dir := filepath.Join(filepath.Dir(s.dbPath), "_backup")
	if !strings.EqualFold(filepath.Dir(p), dir) || !strings.EqualFold(filepath.Ext(p), ".db") {
		return "", fmt.Errorf("копия базы должна лежать в %s и быть файлом .db", dir)
	}
	if fi, err := os.Stat(p); err != nil || fi.IsDir() {
		return "", fmt.Errorf("копии базы нет: %s", p)
	}
	return p, nil
}

// POST /api/restore/request?scope=heard|all[&from=<копия базы>] — «только с этого компьютера». Ставит в список «ждём
// файл с телефона» песни, у которых не осталось файла на диске: scope=heard (по умолчанию) — только слушанные/лайкнутые
// на телефоне и избранные, scope=all — все, кроме помеченных «больше не качать». Кого на телефоне нет, телефон сам
// сообщит. Без from — песни, чьи записи ещё в каталоге. С from (файл из папки _backup рядом с базой) — песни, чьи записи
// уже убрала «уборка» каталога (21.09.2026, 23:19Z Alex нажал плашку): их записи возвращаются в каталог из копии базы,
// файл придёт на прежнее место.
func (s *Service) hRestoreRequest(w http.ResponseWriter, r *http.Request) {
	scope := r.URL.Query().Get("scope")
	if scope == "" {
		scope = "heard"
	}
	if scope != "heard" && scope != "all" {
		http.Error(w, "scope: heard или all", 400)
		return
	}
	var (
		rows   []localdb.RestoreRow
		dead   int
		ghosts int
	)
	if from := r.URL.Query().Get("from"); from != "" {
		backup, err := s.backupFile(from)
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		cands, err := s.db.RestoreBackupCandidates(backup, scope == "heard")
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		dead = len(cands)
		for _, c := range cands {
			local := s.localPath(c.Path)
			if fi, err := os.Stat(pathRoot(local)); err != nil || !fi.IsDir() {
				continue // диск или папка музыки недоступны — за такие не решаем
			}
			if _, err := os.Stat(local); !errors.Is(err, fs.ErrNotExist) {
				continue // файл уже на месте (скан подберёт) или проверить не вышло
			}
			rows = append(rows, c)
		}
		if ghosts, err = s.db.RestoreGhosts(backup, rows); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
	} else {
		elig, err := s.db.RestoreEligible(scope == "heard")
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		rep := s.findMissing()
		dead = rep.Songs
		for _, m := range rep.Dead {
			if elig[m.TrackID] {
				rows = append(rows, localdb.RestoreRow{TrackID: m.TrackID, FileID: m.FileID, Path: m.DBPath, Size: m.Size})
			}
		}
	}
	added, err := s.db.AddRestoreRequests(rows)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if s.recon != nil {
		s.recon.forget()
	}
	_ = s.db.AddServerLog("info", "", "", fmt.Sprintf(
		"возврат песен с телефона (%s): без файла на диске %d, подходит %d, записей возвращено из копии базы %d, поставлено в очередь %d",
		scope, dead, len(rows), ghosts, added), 0)
	writeJSON(w, map[string]any{"scope": scope, "dead": dead, "candidates": len(rows), "ghosts": ghosts, "added": added})
}

// POST /api/restore/cancel — «только с этого компьютера»: снять очередь (то, что уже вернулось, остаётся).
func (s *Service) hRestoreCancel(w http.ResponseWriter, r *http.Request) {
	n, err := s.db.CancelRestore()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if s.recon != nil {
		s.recon.forget()
	}
	writeJSON(w, map[string]any{"cancelled": n})
}

// GET /api/restore/status — сколько ждёт, вернулось, не нашлось на телефоне, не принято.
func (s *Service) hRestoreStatus(w http.ResponseWriter, r *http.Request) {
	counts, wantedBytes, err := s.db.RestoreCounts()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]any{
		"wanted": counts[localdb.RestoreWanted], "wanted_bytes": wantedBytes, "done": counts[localdb.RestoreDone],
		"phone_missing": counts[localdb.RestorePhoneMissing], "failed": counts[localdb.RestoreFailed],
	})
}

// GET /api/restore/wanted — какие песни ждут файл с телефона (телефон смотрит, что у него из этого есть).
func (s *Service) hRestoreWanted(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.RestoreWantedList()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, rows)
}

// POST /api/restore/missing {"ids":[...]} — телефон сообщает, что этих песен у него нет: ждать файл перестаём.
func (s *Service) hRestoreMissing(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&body); err != nil {
		http.Error(w, "нужен список id: "+err.Error(), 400)
		return
	}
	n, err := s.db.MarkRestorePhoneMissing(body.IDs)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if s.recon != nil {
		s.recon.forget()
	}
	writeJSON(w, map[string]any{"marked": n})
}

// PUT /api/restore/upload/{id} — тело запроса — файл песни (как лежит на телефоне). Кладём на прежнее место.
func (s *Service) hRestoreUpload(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	restoreMu.Lock()
	defer restoreMu.Unlock()

	row, ok, err := s.db.RestoreByTrack(id)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if !ok {
		http.Error(w, "этой песни нет в списке возврата", http.StatusNotFound)
		return
	}
	if row.State != localdb.RestoreWanted {
		http.Error(w, "песня уже не ждёт файл: "+row.State, http.StatusConflict)
		return
	}
	local := s.localPath(row.Path)
	ext := strings.ToLower(filepath.Ext(local))
	if _, isAudio := audioExt[ext]; !isAudio {
		http.Error(w, "у песни не аудио-расширение: "+ext, http.StatusUnsupportedMediaType)
		return
	}
	if fi, err := os.Stat(pathRoot(local)); err != nil || !fi.IsDir() {
		http.Error(w, "диск или папка с музыкой недоступны — вернуть не могу", http.StatusServiceUnavailable)
		return
	}
	if _, err := os.Stat(local); err == nil {
		_ = s.db.SetRestoreState(id, localdb.RestoreDone, "")
		writeJSON(w, map[string]any{"status": "exists"})
		return
	} else if !errors.Is(err, fs.ErrNotExist) {
		http.Error(w, err.Error(), 500)
		return
	}

	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		http.Error(w, "не смог создать папку: "+err.Error(), 500)
		return
	}
	tmp := local + restoreTmpSuffix
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		http.Error(w, "не смог открыть файл для записи: "+err.Error(), 500)
		return
	}
	n, copyErr := io.Copy(f, http.MaxBytesReader(w, r.Body, restoreMaxBytes))
	closeErr := f.Close()
	if copyErr != nil || closeErr != nil {
		_ = os.Remove(tmp)
		http.Error(w, fmt.Sprintf("файл не дошёл целиком: %v %v", copyErr, closeErr), http.StatusBadRequest)
		return
	}
	reject := func(reason string) {
		_ = os.Remove(tmp)
		_ = s.db.SetRestoreState(id, localdb.RestoreFailed, reason)
		_ = s.db.AddServerLog("warn", row.Artist, row.Title, "возврат с телефона: файл не принят — "+reason, n)
		http.Error(w, reason, http.StatusUnprocessableEntity)
	}
	head := make([]byte, 16)
	if hf, err := os.Open(tmp); err == nil {
		k, _ := io.ReadFull(hf, head)
		head = head[:k]
		_ = hf.Close()
	}
	if n == 0 || !looksLikeAudio(ext, head) {
		reject("начало файла не похоже на " + ext)
		return
	}
	if row.Size > 0 && n*10 < row.Size*9 {
		reject(fmt.Sprintf("пришло %d байт из прежних %d — похоже на обрезок", n, row.Size))
		return
	}
	if _, err := os.Stat(local); err == nil {
		_ = os.Remove(tmp) // пока принимали, файл уже появился — не перезаписываем
		_ = s.db.SetRestoreState(id, localdb.RestoreDone, "")
		writeJSON(w, map[string]any{"status": "exists"})
		return
	}
	if err := os.Rename(tmp, local); err != nil {
		_ = os.Remove(tmp)
		http.Error(w, "не смог положить файл на место: "+err.Error(), 500)
		return
	}
	if row.FileID != "" {
		_ = s.db.RelinkFile(row.FileID, row.Path, n) // тот же путь, размер — настоящий
	}
	_ = s.db.SetRestoreState(id, localdb.RestoreDone, "")
	if s.recon != nil {
		s.recon.forget()
	}
	_ = s.db.AddServerLog("info", row.Artist, row.Title, "вернула с телефона на прежнее место: "+local, n)
	writeJSON(w, map[string]any{"status": "ok", "bytes": n})
}
