package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"soundflow/server/internal/db"
)

// Контекстное меню окна (Alex TG 20039–20045, 19.09.2026): правая кнопка на
// песне и на папке — играть, показать в проводнике, добавить/убрать на
// телефоне, удалить навсегда.

// bigDeleteThreshold — с какого числа песен перед удалением программа сама
// сохраняет копию базы (а окно просит напечатать слово «удалить»).
const bigDeleteThreshold = 24

// запуск проводника — переменные, чтобы тесты не открывали окна на экране
var (
	revealFn     = revealInExplorer
	openFolderFn = openFolderInExplorer
)

// localOnly — ручка только с этого компьютера. /api/* висит и на телефонном
// сервере (0.0.0.0:8091), то есть доступно всей домашней сети; удалять файлы и
// запускать проводник с чужого устройства нельзя. «Свой компьютер» — см. isThisComputer.
func localOnly(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !fromWindow(r) && !isThisComputer(r.RemoteAddr) {
			host, _, _ := net.SplitHostPort(r.RemoteAddr)
			http.Error(w, "эта команда только с самого компьютера (запрос пришёл с "+host+")", http.StatusForbidden)
			return
		}
		h(w, r)
	}
}

type fromWindowKey struct{}

// markFromWindow — метка «запрос пришёл через окно программы». У запросов окна Wails (v2.15,
// pkg/assetserver/assetserver_webview.go) RemoteAddr всегда заглушка 192.0.2.1:1234 (RFC 5737): по
// адресу их не отличить от чужих, поэтому «своё» узнаём по ПУТИ запроса. Метку ставит только
// APIRouter() (его отдаём Wails); телефонный сервер (настоящий TCP на 0.0.0.0:8091) её не ставит и
// по сети её не подделать. Alex TG 20090: «запрос пришёл с 192.0.2.1» — окно не узнавалось.
func markFromWindow(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), fromWindowKey{}, true)))
	})
}

func fromWindow(r *http.Request) bool {
	v, _ := r.Context().Value(fromWindowKey{}).(bool)
	return v
}

// isThisComputer — запрос пришёл с самого этого компьютера: с «петли» (127.0.0.1, ::1); с любого из
// СОБСТВЕННЫХ адресов ПК (браузер на этом же ПК, открывший программу по адресу 192.168.x.x:8091,
// приходит именно с него — так у Alex 19.09.2026 «Не получилось включить песню: эта команда только
// с самого компьютера», TG 20083); либо без разбираемого адреса. Окно Wails сюда НЕ относится — его
// узнаёт fromWindow (у него заглушка 192.0.2.1). Чужое устройство сети — нет.
func isThisComputer(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return true // окно Wails приходит без адреса
	}
	if i := strings.IndexByte(host, '%'); i >= 0 {
		host = host[:i] // зона IPv6: fe80::1%Ethernet
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return true // не IP (у Wails бывает имя) — пускаем, как раньше
	}
	if ip.IsLoopback() {
		return true
	}
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.Equal(ip) {
			return true
		}
	}
	return false
}

// ---------------- телефон: состояние и план ----------------

type phoneStateResp struct {
	DeviceID   string   `json:"device_id"`
	Name       string   `json:"name"`
	OnDevice   []string `json:"on_device"`
	PlanAdd    []string `json:"plan_add"`
	PlanRemove []string `json:"plan_remove"`
}

// GET /api/phone/state — что сейчас на «живом» телефоне (заходил последним) и
// что уже лежит в плане; меню по этому решает, что писать: «Добавить на
// телефон» или «Убрать с телефона». Устройств нет → device_id пустой.
func (s *Service) hPhoneState(w http.ResponseWriter, r *http.Request) {
	out := phoneStateResp{OnDevice: []string{}, PlanAdd: []string{}, PlanRemove: []string{}}
	id, name, _, ok, err := s.db.LatestDevice()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if !ok {
		writeJSON(w, out)
		return
	}
	out.DeviceID, out.Name = id, name
	have, err := s.db.DeviceTrackIDs(id)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	for tid := range have {
		out.OnDevice = append(out.OnDevice, tid)
	}
	add, remove, _, _, err := s.db.Plan(id)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if add != nil {
		out.PlanAdd = add
	}
	if remove != nil {
		out.PlanRemove = remove
	}
	writeJSON(w, out)
}

// POST /api/phone/plan  body {"add":[ids],"remove":[ids]}
// Дополняет план «живого» телефона (не заменяет: в плане может лежать другой
// невыполненный список). Телефон выполнит при следующем заходе.
func (s *Service) hPhonePlan(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Add    []string `json:"add"`
		Remove []string `json:"remove"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || (len(body.Add) == 0 && len(body.Remove) == 0) {
		http.Error(w, "нужно тело {add:[…], remove:[…]}", 400)
		return
	}
	id, name, _, ok, err := s.db.LatestDevice()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if !ok {
		http.Error(w, "телефон ещё ни разу не заходил — плану некуда ложиться", 409)
		return
	}
	// добавлять можно только то, что есть в каталоге (убранное/чёрный список выпадает)
	add := body.Add
	if len(add) > 0 {
		cards, err := s.db.TracksByIDs(add)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		known := make([]string, 0, len(cards))
		for _, c := range cards {
			known = append(known, c.ID)
		}
		add = known
	}
	nAdd, nRemove, err := s.db.MergePlan(id, add, body.Remove)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "", fmt.Sprintf("из меню окна: в план телефона +%d −%d (всего в плане +%d −%d)", len(add), len(body.Remove), nAdd, nRemove), 0)
	writeJSON(w, map[string]any{"saved": true, "device": name, "added": len(add), "removed": len(body.Remove), "plan_add": nAdd, "plan_remove": nRemove})
}

// ---------------- удалить навсегда ----------------

type deleteResult struct {
	Deleted      int      `json:"deleted"`       // песен убрано (каталог + метка + телефон)
	Failed       int      `json:"failed"`        // не вышло (файл занят и т.п.) — осталась как была
	Skipped      int      `json:"skipped"`       // такой песни уже нет в каталоге
	FilesMoved   int      `json:"files_moved"`   // файлов перенесено в _deleted
	FilesMissing int      `json:"files_missing"` // файла на диске уже не было
	Bytes        int64    `json:"bytes"`
	Copies       int      `json:"copies"`        // файлов-копий песен перенесено (другие папки, тот же исполнитель и название)
	CopiesFailed int      `json:"copies_failed"` // копий перенести не удалось (файл занят) — остались на месте
	TrashDir     string   `json:"trash_dir,omitempty"`
	Backup       string   `json:"backup,omitempty"`
	Errors       []string `json:"errors,omitempty"`
}

// POST /api/tracks/delete-forever  body {"ids":[…]}
//
// «Удалить навсегда» из меню окна для песни и для папки (Alex TG 20041: «и на
// папке тоже удалить навсегда»). На каждую песню то же, что делает «Удалить
// полностью» в карточке телефона (devdelete.go, TG 19160):
//
//  1. песня уходит с телефона (в план на удаление, дополняем, не затираем);
//  2. убирается из каталога ПК;
//  3. её ключ получает метку blocked — «Найти трек»/докачка больше не скачают;
//  4. файл переносится (НЕ стирается — глобальное правило: деструктив только с
//     откатом) в <диск>\_deleted\<дата-время>\<путь без буквы диска>. Тот же
//     диск — перенос мгновенный (переименование, без копирования гигабайтов), а
//     вложенные папки сохраняются, чтобы вернуть можно было простым
//     перетаскиванием. Пустые папки после переноса убираются;
//  5. так же уходят КОПИИ песни — другие файлы с тем же исполнителем и названием в
//     других папках (Alex TG 20177, вариант 2: «удалять песню целиком»), см. copies.go.
//
// Больше bigDeleteThreshold песен — перед удалением копия базы в
// <папка_базы>\_backup (не вышла копия — не удаляем ничего).
// Песня, у которой файл не переносится (занят), остаётся нетронутой целиком.
func (s *Service) hDeleteForever(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || len(body.IDs) == 0 {
		http.Error(w, "нужно тело {ids:[…]}", 400)
		return
	}
	if s.store == nil {
		http.Error(w, "сервис ещё поднимается, попробуй через пару секунд", 503)
		return
	}
	res, err := s.deleteForever(r.Context(), body.IDs)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, res)
}

func (s *Service) deleteForever(ctx context.Context, rawIDs []string) (deleteResult, error) {
	var res deleteResult
	seen := map[string]bool{}
	ids := make([]string, 0, len(rawIDs))
	for _, id := range rawIDs {
		if id != "" && !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	if len(ids) > bigDeleteThreshold {
		p, err := s.backupDB("before-delete")
		if err != nil {
			return res, fmt.Errorf("не смог сохранить копию базы, ничего не удалено: %w", err)
		}
		res.Backup = p
	}
	stamp := time.Now().Format("20060102-150405")
	stopAt := s.libraryRoots()
	copies := s.findCopyFiles(ctx, s.copiesWanted(ctx, ids)) // один проход по папке на всю пачку

	var removed []string
	var movedDirs []string
	for _, id := range ids {
		normKey, canonical, ok, err := s.store.TrackForDeletion(ctx, id)
		if err != nil {
			res.Failed++
			res.Errors = append(res.Errors, id+": "+err.Error())
			continue
		}
		if !ok {
			res.Skipped++
			continue
		}
		artist, title, _, _ := s.store.TrackArtistTitle(ctx, id)
		local := s.localPath(canonical)

		var size int64
		if fi, e := os.Stat(local); e == nil && !fi.IsDir() {
			size = fi.Size()
		}
		moved, mvErr := s.moveToDeletedTree(local, stamp)
		if mvErr != nil {
			res.Failed++
			res.Errors = append(res.Errors, artist+" — "+title+": "+mvErr.Error())
			_ = s.db.AddServerLog("error", artist, title, "не смог перенести файл в _deleted, песня осталась: "+mvErr.Error(), 0)
			continue
		}
		if err := s.store.DeleteTrackByKey(ctx, normKey); err != nil {
			if moved != "" { // каталог не тронули — файл возвращаем на место
				_ = os.Rename(moved, local)
			}
			res.Failed++
			res.Errors = append(res.Errors, artist+" — "+title+": "+err.Error())
			continue
		}
		_ = s.store.UpsertLegacyMark(ctx, db.LegacyMark{
			Key: normKey, Kind: "blocked", Artist: artist, Title: title, At: time.Now(),
		})
		removed = append(removed, id)
		res.Deleted++
		for _, cp := range copies[normKey] { // копии той же песни в других папках
			cm, cErr := s.moveToDeletedTree(cp, stamp)
			if cErr != nil {
				res.CopiesFailed++
				res.Errors = append(res.Errors, "копия «"+artist+" — "+title+"» ("+cp+"): "+cErr.Error())
				continue
			}
			if cm != "" {
				res.Copies++
				if fi, e := os.Stat(cm); e == nil {
					res.Bytes += fi.Size()
				}
				movedDirs = append(movedDirs, filepath.Dir(cp))
			}
		}
		if moved != "" {
			res.FilesMoved++
			res.Bytes += size
			movedDirs = append(movedDirs, filepath.Dir(local))
			if res.TrashDir == "" {
				res.TrashDir = trashStampDir(local, s.trashRoot(local), stamp)
			}
		} else {
			res.FilesMissing++
		}
	}

	if len(removed) > 0 {
		if dev, _, _, ok, err := s.db.LatestDevice(); err == nil && ok {
			if _, _, err := s.db.MergePlan(dev, nil, removed); err != nil {
				res.Errors = append(res.Errors, "план телефона: "+err.Error())
			}
		}
		pruneEmptyDirs(movedDirs, stopAt)
	}
	_ = s.db.AddServerLog("info", "", "", fmt.Sprintf(
		"удалено навсегда из окна: %d песен (файлов перенесено %d, копий перенесено %d, не удалось %d+%d), файлы в %s, копия базы: %s",
		res.Deleted, res.FilesMoved, res.Copies, res.Failed, res.CopiesFailed, orDash(res.TrashDir), orDash(res.Backup)), res.Bytes)
	return res, nil
}

func orDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

// trashRoot — куда складывать удалённое для файла local: <диск>\_deleted. Тот же
// том, что и у файла, чтобы перенос был переименованием. trashRootOverride — для тестов.
func (s *Service) trashRoot(local string) string {
	if s.trashRootOverride != "" {
		return s.trashRootOverride
	}
	vol := filepath.VolumeName(local)
	if vol == "" {
		return filepath.Join(filepath.Dir(s.dbPath), "_deleted")
	}
	return vol + `\_deleted`
}

func trashStampDir(local, root, stamp string) string { return filepath.Join(root, stamp) }

// moveToDeletedTree — перенести файл в <trashRoot>\<stamp>\<путь без диска>.
// Файла уже нет — не ошибка (вернёт "").
func (s *Service) moveToDeletedTree(local, stamp string) (string, error) {
	if local == "" {
		return "", nil
	}
	fi, err := os.Stat(local)
	if err != nil {
		return "", nil
	}
	if fi.IsDir() {
		return "", fmt.Errorf("это папка, а не файл: %s", local)
	}
	rel := strings.TrimLeft(strings.TrimPrefix(local, filepath.VolumeName(local)), `\/`)
	dst := filepath.Join(s.trashRoot(local), stamp, rel)
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", err
	}
	if _, err := os.Stat(dst); err == nil { // такое имя уже есть в этой корзине — не затираем
		dst = strings.TrimSuffix(dst, filepath.Ext(dst)) + "__" + fmt.Sprint(time.Now().UnixNano()) + filepath.Ext(dst)
	}
	if err := os.Rename(local, dst); err != nil {
		return "", err
	}
	return dst, nil
}

// libraryRoots — папки, которые нельзя убирать даже пустыми: папка-источник из
// настроек. Плюс любая папка прямо под корнем диска (G:\музыка) — см. pruneEmptyDirs.
func (s *Service) libraryRoots() []string {
	dir, _, err := s.db.GetSetting(settingWatchDir)
	if err != nil || dir == "" {
		return nil
	}
	return []string{filepath.Clean(dir)}
}

// pruneEmptyDirs — убрать папки, которые опустели после переноса файлов: от
// папки файла вверх, пока пусто (os.Remove не трогает непустую). Не трогаем
// папку-источник и любую папку прямо под корнем диска.
func pruneEmptyDirs(dirs []string, stopAt []string) {
	seen := map[string]bool{}
	for _, d := range dirs {
		for cur := filepath.Clean(d); cur != "" && !seen[strings.ToLower(cur)]; cur = filepath.Dir(cur) {
			seen[strings.ToLower(cur)] = true
			parent := filepath.Dir(cur)
			if parent == cur || parent == filepath.VolumeName(cur)+`\` || parent == "." {
				break // cur — корень диска или папка прямо под ним
			}
			stop := false
			for _, r := range stopAt {
				if strings.EqualFold(filepath.Clean(r), cur) {
					stop = true
				}
			}
			if stop {
				break
			}
			if err := os.Remove(cur); err != nil { // непустая (или занята) — выше не идём
				break
			}
		}
	}
}

// backupDB — копия базы через VACUUM INTO (целостная, при работающей программе).
func (s *Service) backupDB(tag string) (string, error) {
	dir := filepath.Join(filepath.Dir(s.dbPath), "_backup")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	dst := filepath.Join(dir, "soundflow-"+time.Now().Format("20060102-150405")+"-"+tag+".db")
	if _, err := s.db.SQL().Exec(`VACUUM INTO ?`, dst); err != nil {
		return "", err
	}
	if fi, err := os.Stat(dst); err != nil || fi.Size() == 0 {
		return "", fmt.Errorf("копия базы не создалась: %s", dst)
	}
	return dst, nil
}

// ---------------- показать в проводнике ----------------

// POST /api/reveal  body {"track_id":"…"} — открыть проводник с выделенным файлом песни.
func (s *Service) hReveal(w http.ResponseWriter, r *http.Request) {
	var body struct {
		TrackID string `json:"track_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.TrackID == "" {
		http.Error(w, "нужно тело {track_id}", 400)
		return
	}
	canonical, ok, err := s.db.TrackFilePath(body.TrackID)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if !ok {
		http.Error(w, "такой песни нет в каталоге", 404)
		return
	}
	local := s.localPath(canonical)
	if _, err := os.Stat(local); err != nil {
		http.Error(w, "файла нет на диске: "+local, 404)
		return
	}
	if err := revealFn(local); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

// POST /api/open-folder  body {"path":"G:\\музыка\\HitZone"} — открыть папку в проводнике.
// Путь должен быть папкой из каталога (или выше песни каталога): произвольные
// пути не открываем.
func (s *Service) hOpenFolder(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Path == "" {
		http.Error(w, "нужно тело {path}", 400)
		return
	}
	inLib, err := s.pathInLibrary(body.Path)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if !inLib {
		http.Error(w, "это не папка из каталога", 403)
		return
	}
	local := s.localPath(filepath.Clean(body.Path))
	if fi, err := os.Stat(local); err != nil || !fi.IsDir() {
		http.Error(w, "папки нет на диске: "+local, 404)
		return
	}
	if err := openFolderFn(local); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

func normPath(p string) string {
	return strings.ToLower(strings.TrimRight(strings.ReplaceAll(p, "/", `\`), `\`))
}

// pathInLibrary — папка dir лежит выше (или это папка) хотя бы одного файла каталога.
func (s *Service) pathInLibrary(dir string) (bool, error) {
	if strings.ContainsAny(dir, `"<>|*?`) {
		return false, nil
	}
	clean := filepath.Clean(dir)
	want := normPath(clean)
	// корень диска («G:\») и пустой путь — не папка каталога, их не открываем
	if want == "" || want == "." || clean == filepath.VolumeName(clean)+`\` || want == normPath(filepath.VolumeName(clean)) {
		return false, nil
	}
	rows, err := s.db.SQL().Query(`SELECT file_path FROM track_files WHERE rejected = 0`)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var fp string
		if err := rows.Scan(&fp); err != nil {
			return false, err
		}
		if strings.HasPrefix(normPath(fp), want+`\`) {
			return true, nil
		}
	}
	return false, rows.Err()
}
