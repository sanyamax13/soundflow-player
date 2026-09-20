package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"soundflow/server/internal/localdb"
)

// Сверка каталога с диском (Alex TG 20231, 21.09.2026: «надо научить программу самой убирать и добавлять
// в каталог»). Добавляет скан (jobs.go: при запуске, при возврате в окно и по таймеру), убирает эта
// сверка: песню, чьего файла больше нет на диске, программа сама убирает из каталога. Alex удаляет ненужные
// папки Проводником (20.09.2026 — 7 200 песен разом), и без сверки каталог копил «мёртвые» записи:
// в окне они не играли, а «Волна» и скачивание считали их «уже есть» и не предлагали заново.
//
// Защита от беды (диск на минуту отключился, папку переименовали):
//   - файл считается пропавшим, только если существует «корень» его пути — диск и первая папка (G:\музыка);
//   - сама программа убирает лишь то, что остаётся без файла не меньше reconcileGrace (две проверки подряд);
//   - если разом пропало больше reconcileAutoMax — сама не убирает, а показывает в окне плашку с кнопкой;
//   - больше bigDeleteThreshold песен — перед уборкой копия базы (не вышла — ничего не убираем);
//   - трогаем только строки каталога: файлы на диске, метки, лайки и события — нет; телефону «стереть» не
//     посылаем (в «Плане синхронизации» такие песни будут «нет в каталоге», решает Alex).
const (
	reconcileFirstDelay = 3 * time.Minute
	reconcileEvery      = 30 * time.Minute
	reconcileGrace      = 10 * time.Minute
	reconcileAutoMax    = 300
	missingCacheTTL     = 20 * time.Second // окно спрашивает часто, диск обходить каждый раз незачем
)

type missingFile struct {
	FileID, TrackID, Path, Folder string
	Size                          int64
}

type folderCount struct {
	Folder string `json:"folder"`
	Songs  int    `json:"songs"`
}

type missingReport struct {
	Files   []missingFile
	Songs   int // песен, у которых не осталось ни одного файла на диске
	Bytes   int64
	Folders []folderCount // по убыванию, не больше 12
}

// pathParts — диск и папки/файл пути без пустых частей (разделители и \, и /).
func pathParts(p string) (vol string, parts []string) {
	vol = filepath.VolumeName(p)
	for _, s := range strings.Split(strings.ReplaceAll(p[len(vol):], `\`, "/"), "/") {
		if s != "" {
			parts = append(parts, s)
		}
	}
	return vol, parts
}

func joinParts(vol string, parts ...string) string {
	sep := string(filepath.Separator)
	return vol + sep + strings.Join(parts, sep)
}

// pathRoot — «корень» пути: диск и первая папка (G:\музыка); файл прямо в корне диска — сам диск.
func pathRoot(p string) string {
	vol, parts := pathParts(p)
	if len(parts) >= 2 {
		return joinParts(vol, parts[0])
	}
	return joinParts(vol)
}

// pathFolder — папка для сводки: корень и следующая папка (G:\музыка\HitZone).
func pathFolder(p string) string {
	vol, parts := pathParts(p)
	switch {
	case len(parts) >= 3:
		return joinParts(vol, parts[0], parts[1])
	case len(parts) == 2:
		return joinParts(vol, parts[0])
	}
	return joinParts(vol)
}

// findMissing — какие записи файлов каталога указывают на файлы, которых нет на диске.
func (s *Service) findMissing() missingReport {
	var rep missingReport
	refs, err := s.db.AllFileRefs()
	if err != nil {
		log.Printf("сверка каталога: не прочитала записи файлов: %v", err)
		return rep
	}
	total := map[string]int{}
	for _, r := range refs {
		if r.TrackID != "" {
			total[r.TrackID]++
		}
	}
	rootOK := map[string]bool{}
	gone := map[string]int{}
	for _, r := range refs {
		local := s.localPath(r.Path)
		root := pathRoot(local)
		ok, seen := rootOK[root]
		if !seen {
			fi, err := os.Stat(root)
			ok = err == nil && fi.IsDir()
			rootOK[root] = ok
		}
		if !ok {
			continue // диск не подключён или папку переименовали — за такие файлы не решаем
		}
		if _, err := os.Stat(local); !errors.Is(err, fs.ErrNotExist) {
			continue // файл на месте (или проверить не вышло — тоже не считаем пропавшим)
		}
		rep.Files = append(rep.Files, missingFile{FileID: r.ID, TrackID: r.TrackID, Path: local, Folder: pathFolder(local), Size: r.Size})
		if r.TrackID != "" {
			gone[r.TrackID]++
		}
	}
	perFolder := map[string]int{}
	counted := map[string]bool{}
	for _, m := range rep.Files {
		rep.Bytes += m.Size
		if m.TrackID == "" || counted[m.TrackID] || gone[m.TrackID] != total[m.TrackID] {
			continue
		}
		counted[m.TrackID] = true
		rep.Songs++
		perFolder[m.Folder]++
	}
	for f, n := range perFolder {
		rep.Folders = append(rep.Folders, folderCount{Folder: f, Songs: n})
	}
	sort.Slice(rep.Folders, func(i, j int) bool {
		if rep.Folders[i].Songs != rep.Folders[j].Songs {
			return rep.Folders[i].Songs > rep.Folders[j].Songs
		}
		return rep.Folders[i].Folder < rep.Folders[j].Folder
	})
	if len(rep.Folders) > 12 {
		rep.Folders = rep.Folders[:12]
	}
	return rep
}

// removeMissing — убрать из каталога записи по id записей файлов; больше bigDeleteThreshold песен — сперва копия
// базы. how — для журнала («сама» / «по кнопке в окне»).
func (s *Service) removeMissing(ids []string, how string) (files, songs int, backup string, err error) {
	if len(ids) == 0 {
		return 0, 0, "", nil
	}
	if len(ids) > bigDeleteThreshold {
		if backup, err = s.backupDB("before-reconcile"); err != nil {
			return 0, 0, "", fmt.Errorf("не смог сохранить копию базы, ничего не убрано: %w", err)
		}
	}
	files, songs, err = s.db.RemoveFileRecords(ids)
	if err != nil {
		return 0, 0, backup, err
	}
	_ = s.db.AddServerLog("info", "", "", fmt.Sprintf(
		"каталог сверен с диском (%s): убрано песен %d, записей файлов %d — файлов на диске нет; копия базы: %s",
		how, songs, files, orDash(backup)), 0)
	return files, songs, backup, nil
}

// reconciler — фон: раз в reconcileEvery (и после каждого скана) смотрит, что пропало с диска.
type reconciler struct {
	s    *Service
	run  sync.Mutex // одна сверка за раз
	mu   sync.Mutex
	seen map[string]time.Time // id записи файла → когда впервые увидели без файла
	now  func() time.Time
	stop chan struct{}
	once sync.Once

	cacheMu  sync.Mutex
	cacheAt  time.Time
	cacheRep missingReport
}

func newReconciler(s *Service) *reconciler {
	return &reconciler{s: s, seen: map[string]time.Time{}, now: time.Now, stop: make(chan struct{})}
}

// Start — таймер: сначала скан папки-источника (он сам позовёт сверку по окончании), нет папки — только сверка.
func (r *reconciler) Start() {
	go func() {
		t := time.NewTimer(reconcileFirstDelay)
		defer t.Stop()
		for {
			select {
			case <-r.stop:
				return
			case <-t.C:
				r.tick()
				t.Reset(reconcileEvery)
			}
		}
	}()
}

func (r *reconciler) Stop() {
	if r != nil {
		r.once.Do(func() { close(r.stop) })
	}
}

func (r *reconciler) tick() {
	s := r.s
	if dir, _, _ := s.db.GetSetting(settingWatchDir); dir != "" {
		if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
			if id := s.jobs.StartScan(dir); id != "" {
				return // после скана сверка запустится сама (AfterScan)
			}
		}
	}
	r.auto()
}

// AfterScan — скан закончился: сверить каталог с диском. Можно звать на nil (тесты без сверки).
func (r *reconciler) AfterScan() {
	if r == nil {
		return
	}
	go r.auto()
}

// auto — сама убирает записи, файлы которых пропали давно и в разумном количестве (см. защиту выше).
func (r *reconciler) auto() {
	if !r.run.TryLock() {
		return
	}
	defer r.run.Unlock()
	rep := r.s.findMissing()
	now := r.now()
	r.mu.Lock()
	seen := make(map[string]time.Time, len(rep.Files))
	for _, m := range rep.Files {
		if t, ok := r.seen[m.FileID]; ok {
			seen[m.FileID] = t
		} else {
			seen[m.FileID] = now
		}
	}
	r.seen = seen // кто вернулся на место — забыт
	r.mu.Unlock()
	if len(rep.Files) == 0 || len(rep.Files) > reconcileAutoMax {
		return // пропаж нет; или их много — ждём решения Alex в окне
	}
	var ripe []string
	for _, m := range rep.Files {
		if now.Sub(seen[m.FileID]) >= reconcileGrace {
			ripe = append(ripe, m.FileID)
		}
	}
	if _, _, _, err := r.s.removeMissing(ripe, "сама"); err != nil {
		_ = r.s.db.AddServerLog("error", "", "", "сверка каталога: "+err.Error(), 0)
	}
}

// report — то, что показывает окно; не чаще раза в missingCacheTTL обходит диск.
func (r *reconciler) report() missingReport {
	r.cacheMu.Lock()
	defer r.cacheMu.Unlock()
	if !r.cacheAt.IsZero() && r.now().Sub(r.cacheAt) < missingCacheTTL {
		return r.cacheRep
	}
	r.cacheRep = r.s.findMissing()
	r.cacheAt = r.now()
	return r.cacheRep
}

func (r *reconciler) forget() {
	r.cacheMu.Lock()
	r.cacheAt = time.Time{}
	r.cacheMu.Unlock()
}

// GET /api/catalog/missing — что пропало с диска и ждёт решения (плашка в окне).
func (s *Service) hMissing(w http.ResponseWriter, r *http.Request) {
	if s.recon == nil {
		writeJSON(w, map[string]any{"files": 0, "songs": 0, "bytes": 0, "folders": []folderCount{}, "needs_confirm": false})
		return
	}
	rep := s.recon.report()
	folders := rep.Folders
	if folders == nil {
		folders = []folderCount{}
	}
	writeJSON(w, map[string]any{
		"files": len(rep.Files), "songs": rep.Songs, "bytes": rep.Bytes, "folders": folders,
		"needs_confirm": len(rep.Files) > reconcileAutoMax,
	})
}

// POST /api/catalog/missing/clean — Alex нажал «Убрать из каталога»: заново проверить диск и убрать всё, что
// пропало (без выдержки — решение принято им).
func (s *Service) hMissingClean(w http.ResponseWriter, r *http.Request) {
	if s.recon == nil {
		http.Error(w, "сверка ещё не запущена", 503)
		return
	}
	if !s.recon.run.TryLock() {
		http.Error(w, "сверка уже идёт — попробуй через минуту", http.StatusConflict)
		return
	}
	defer s.recon.run.Unlock()
	defer s.recon.forget()
	rep := s.findMissing()
	ids := make([]string, len(rep.Files))
	for i, m := range rep.Files {
		ids[i] = m.FileID
	}
	files, songs, backup, err := s.removeMissing(ids, "по кнопке в окне")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"songs": songs, "files": files, "backup": backup})
}

// relinkMoved — скан нашёл файл песни, которая уже есть в каталоге. Если прежний файл этой песни пропал
// с диска (при существующем корне пути), а этот лежит на месте — папку перенесли: направляем запись на новый
// путь. Так перенос папки не рождает дублей и не теряет лайки, а сверка не убирает песню как пропавшую.
// Прежний файл на месте — это копия, ничего не трогаем.
func (s *Service) relinkMoved(key, newPath string) bool {
	id, old, ok, err := s.db.FileByKey(key)
	if err != nil || !ok || localdb.PathKey(old) == localdb.PathKey(newPath) {
		return false
	}
	oldLocal := s.localPath(old)
	if fi, err := os.Stat(pathRoot(oldLocal)); err != nil || !fi.IsDir() {
		return false // корень старого пути недоступен — судить нельзя
	}
	if _, err := os.Stat(oldLocal); !errors.Is(err, fs.ErrNotExist) {
		return false
	}
	fi, err := os.Stat(newPath)
	if err != nil {
		return false
	}
	return s.db.RelinkFile(id, newPath, fi.Size()) == nil
}

// rescanSoon — через scanFreshFor и чуть больше просканировать папку-источник: только что скачанный торрент-альбом
// ещё «горячий» (скан такие файлы пропускает), а его песни должны попасть в каталог сами.
func (s *Service) rescanSoon() {
	time.AfterFunc(scanFreshFor+15*time.Second, func() {
		if s.db == nil || s.jobs == nil {
			return
		}
		if dir, _, _ := s.db.GetSetting(settingWatchDir); dir != "" {
			if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
				s.jobs.StartScan(dir)
			}
		}
	})
}
