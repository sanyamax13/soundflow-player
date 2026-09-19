package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"soundflow/server/internal/litestore"
	"soundflow/server/internal/localdb"
)

type ctxEnv struct {
	s    *Service
	root string // <tmp>\lib — «папка с музыкой»
	dir  string // <tmp>
}

func ctxFixture(t *testing.T) *ctxEnv {
	t.Helper()
	dir := t.TempDir()
	d, err := localdb.Open(filepath.Join(dir, "soundflow.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	root := filepath.Join(dir, "lib")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	s := &Service{db: d, store: litestore.New(d), dbPath: filepath.Join(dir, "soundflow.db"),
		trashRootOverride: filepath.Join(dir, "trash")}
	return &ctxEnv{s: s, root: root, dir: dir}
}

// addSong — файл на диске (если content != "") + запись в каталоге.
func (e *ctxEnv) addSong(t *testing.T, id, rel, content string) string {
	t.Helper()
	local := filepath.Join(e.root, filepath.FromSlash(rel))
	if content != "" {
		if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(local, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	err := e.s.db.InsertTrackWithFile(
		localdb.NewTrack{ID: id, Artist: "Art " + id, Title: "Title " + id, NormalizedKey: "art " + id + "__title " + id},
		localdb.NewTrackFile{ID: "f_" + id, NormalizedKey: "art " + id + "__title " + id, FilePath: local, SizeBytes: int64(len(content))})
	if err != nil {
		t.Fatal(err)
	}
	return local
}

func (e *ctxEnv) trashFiles(t *testing.T) []string {
	t.Helper()
	var out []string
	_ = filepath.Walk(filepath.Join(e.dir, "trash"), func(p string, fi os.FileInfo, err error) error {
		if err == nil && !fi.IsDir() {
			out = append(out, p)
		}
		return nil
	})
	return out
}

func inCatalog(t *testing.T, s *Service, id string) bool {
	t.Helper()
	_, ok, err := s.db.TrackFilePath(id)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// Папка удаляется: файлы уходят в <trash>\<время>\<путь> с вложенными папками, пустые папки
// исчезают, соседняя папка цела, песни ушли из каталога, стоит blocked, телефон получил remove,
// а прежний план не затёрт.
func TestDeleteForeverFolder(t *testing.T) {
	e := ctxFixture(t)
	s := e.s
	f1 := e.addSong(t, "t1", "HitZone/Hitzone 1/01.mp3", "aaa")
	f2 := e.addSong(t, "t2", "HitZone/Hitzone 1/02.mp3", "bbbb")
	keep := e.addSong(t, "t3", "Other/keep.mp3", "ccccc")
	if _, err := s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"}, nil); err != nil {
		t.Fatal(err)
	}
	if err := s.db.SavePlan("phone", []string{"a-old"}, []string{"r-old"}); err != nil {
		t.Fatal(err)
	}

	res, err := s.deleteForever(context.Background(), []string{"t1", "t2", "t1", ""})
	if err != nil {
		t.Fatal(err)
	}
	if res.Deleted != 2 || res.Failed != 0 || res.FilesMoved != 2 || res.Bytes != 7 || res.Backup != "" {
		t.Errorf("результат: %+v", res)
	}
	for _, f := range []string{f1, f2} {
		if _, err := os.Stat(f); !os.IsNotExist(err) {
			t.Errorf("файл должен уйти с места: %s (%v)", f, err)
		}
	}
	if _, err := os.Stat(keep); err != nil {
		t.Errorf("чужой файл обязан уцелеть: %v", err)
	}
	moved := e.trashFiles(t)
	if len(moved) != 2 {
		t.Fatalf("в корзине ждали 2 файла, есть %v", moved)
	}
	for _, m := range moved {
		if !strings.Contains(m, filepath.Join("HitZone", "Hitzone 1")) {
			t.Errorf("вложенные папки должны сохраниться: %s", m)
		}
		if b, _ := os.ReadFile(m); len(b) == 0 {
			t.Errorf("файл в корзине пуст: %s", m)
		}
	}
	if _, err := os.Stat(filepath.Join(e.root, "HitZone")); !os.IsNotExist(err) {
		t.Errorf("опустевшая папка HitZone должна исчезнуть (%v)", err)
	}
	if _, err := os.Stat(filepath.Join(e.root, "Other")); err != nil {
		t.Errorf("папка с оставшейся песней обязана остаться: %v", err)
	}
	if inCatalog(t, s, "t1") || inCatalog(t, s, "t2") || !inCatalog(t, s, "t3") {
		t.Errorf("каталог: t1/t2 должны уйти, t3 остаться")
	}
	var blocked int
	_ = s.db.SQL().QueryRow(`SELECT count(*) FROM legacy_marks WHERE kind='blocked'`).Scan(&blocked)
	if blocked != 2 {
		t.Errorf("меток «больше не качать» ждали 2, есть %d", blocked)
	}
	add, rem, _, ok, _ := s.db.Plan("phone")
	if !ok || len(add) != 1 || add[0] != "a-old" {
		t.Errorf("прежний add не должен пропасть: %v", add)
	}
	if strings.Join(rem, ",") != "r-old,t1,t2" {
		t.Errorf("remove ждали r-old,t1,t2, получили %v", rem)
	}
}

// Опустела папка-источник из настроек — её не удаляем, даже пустую.
func TestDeleteForeverKeepsWatchDir(t *testing.T) {
	e := ctxFixture(t)
	e.addSong(t, "t1", "Album/01.mp3", "aaa")
	if err := e.s.db.SetSetting(settingWatchDir, e.root); err != nil {
		t.Fatal(err)
	}
	if _, err := e.s.deleteForever(context.Background(), []string{"t1"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(e.root); err != nil {
		t.Errorf("папку-источник удалять нельзя: %v", err)
	}
	if _, err := os.Stat(filepath.Join(e.root, "Album")); !os.IsNotExist(err) {
		t.Errorf("пустой Album должен исчезнуть")
	}
}

// Файла на диске уже нет — песня всё равно уходит из каталога.
func TestDeleteForeverFileAlreadyGone(t *testing.T) {
	e := ctxFixture(t)
	e.addSong(t, "t1", "gone.mp3", "") // файл не создаём
	res, err := e.s.deleteForever(context.Background(), []string{"t1", "нет-такой"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Deleted != 1 || res.FilesMissing != 1 || res.Skipped != 1 || res.Failed != 0 {
		t.Errorf("результат: %+v", res)
	}
	if inCatalog(t, e.s, "t1") {
		t.Errorf("песня должна уйти из каталога")
	}
}

// Файл занят (открыт) — Windows не даст переименовать: песня остаётся целиком (файл, каталог, без метки).
func TestDeleteForeverLockedFileStaysIntact(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("занятый файл переименовать нельзя только в Windows")
	}
	e := ctxFixture(t)
	f := e.addSong(t, "t1", "Album/01.mp3", "aaa")
	e.addSong(t, "t2", "Album/02.mp3", "bbb")
	h, err := os.Open(f) // Go открывает без FILE_SHARE_DELETE
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	res, err := e.s.deleteForever(context.Background(), []string{"t1", "t2"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Deleted != 1 || res.Failed != 1 {
		t.Errorf("ждали deleted=1 failed=1, получили %+v", res)
	}
	if _, err := os.Stat(f); err != nil {
		t.Errorf("занятый файл должен лежать на месте: %v", err)
	}
	if !inCatalog(t, e.s, "t1") || inCatalog(t, e.s, "t2") {
		t.Errorf("каталог: t1 остаётся, t2 ушла")
	}
	var blocked int
	_ = e.s.db.SQL().QueryRow(`SELECT count(*) FROM legacy_marks WHERE kind='blocked'`).Scan(&blocked)
	if blocked != 1 {
		t.Errorf("метка только у t2, а их %d", blocked)
	}
}

// Больше порога — сначала копия базы; папка без копии не удаляется.
func TestDeleteForeverBigBatchMakesBackup(t *testing.T) {
	e := ctxFixture(t)
	var ids []string
	for i := 0; i < bigDeleteThreshold+1; i++ {
		id := fmt.Sprintf("t%02d", i)
		e.addSong(t, id, id+".mp3", "x")
		ids = append(ids, id)
	}
	res, err := e.s.deleteForever(context.Background(), ids)
	if err != nil {
		t.Fatal(err)
	}
	if res.Backup == "" {
		t.Fatalf("ждали копию базы: %+v", res)
	}
	if fi, err := os.Stat(res.Backup); err != nil || fi.Size() == 0 {
		t.Errorf("копия базы не создалась: %v", err)
	}
	if res.Deleted != len(ids) {
		t.Errorf("удалено %d из %d", res.Deleted, len(ids))
	}
	// копия — настоящая база с песнями ДО удаления
	b, err := localdb.Open(res.Backup)
	if err != nil {
		t.Fatalf("копия не открывается: %v", err)
	}
	defer b.Close()
	list, _ := b.CatalogList(1000)
	if len(list) != len(ids) {
		t.Errorf("в копии ждали %d песен (до удаления), есть %d", len(ids), len(list))
	}
}

func TestPhonePlanHandlerMergesAndFiltersUnknown(t *testing.T) {
	e := ctxFixture(t)
	e.addSong(t, "t1", "a.mp3", "x")
	if _, err := e.s.db.SaveSync(localdb.Device{ID: "phone", Name: "Samsung"}, nil); err != nil {
		t.Fatal(err)
	}
	if err := e.s.db.SavePlan("phone", nil, []string{"r-old"}); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	e.s.hPhonePlan(rec, httptest.NewRequest("POST", "/api/phone/plan", strings.NewReader(`{"add":["t1","нет-такой"],"remove":["r2"]}`)))
	if rec.Code != 200 {
		t.Fatalf("код %d: %s", rec.Code, rec.Body.String())
	}
	add, rem, _, _, _ := e.s.db.Plan("phone")
	if strings.Join(add, ",") != "t1" || strings.Join(rem, ",") != "r-old,r2" {
		t.Errorf("план: add=%v remove=%v", add, rem)
	}

	rec = httptest.NewRecorder()
	e.s.hPhonePlan(rec, httptest.NewRequest("POST", "/api/phone/plan", strings.NewReader(`{}`)))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("пустое тело: ждали 400, получили %d", rec.Code)
	}

	// состояние: t1 в плане add, r-old/r2 в remove
	rec = httptest.NewRecorder()
	e.s.hPhoneState(rec, httptest.NewRequest("GET", "/api/phone/state", nil))
	var st phoneStateResp
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatal(err)
	}
	if st.DeviceID != "phone" || len(st.PlanAdd) != 1 || len(st.PlanRemove) != 2 || st.OnDevice == nil {
		t.Errorf("состояние: %+v", st)
	}
}

func TestPhonePlanNoDevice(t *testing.T) {
	e := ctxFixture(t)
	rec := httptest.NewRecorder()
	e.s.hPhonePlan(rec, httptest.NewRequest("POST", "/api/phone/plan", strings.NewReader(`{"add":["x"]}`)))
	if rec.Code != http.StatusConflict {
		t.Errorf("нет телефона: ждали 409, получили %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	e.s.hPhoneState(rec, httptest.NewRequest("GET", "/api/phone/state", nil))
	if !strings.Contains(rec.Body.String(), `"device_id":""`) {
		t.Errorf("состояние без телефона: %s", rec.Body.String())
	}
}

// Команды, меняющие файлы, — только с этого компьютера: запрос с адреса домашней
// сети отклоняется, с localhost и без адреса (окно Wails) проходит.
func TestLocalOnly(t *testing.T) {
	ok := 0
	h := localOnly(func(w http.ResponseWriter, r *http.Request) { ok++ })
	for addr, want := range map[string]int{
		"192.168.1.50:5555": http.StatusForbidden,
		"127.0.0.1:5555":    http.StatusOK,
		"[::1]:5555":        http.StatusOK,
		"":                  http.StatusOK,
		"wails":             http.StatusOK,
	} {
		req := httptest.NewRequest("POST", "/x", nil)
		req.RemoteAddr = addr
		rec := httptest.NewRecorder()
		h(rec, req)
		if rec.Code != want {
			t.Errorf("адрес %q: код %d, ждали %d", addr, rec.Code, want)
		}
	}
	if ok != 4 {
		t.Errorf("обработчик должен сработать 4 раза, сработал %d", ok)
	}
}

// Браузер на ЭТОМ ЖЕ компьютере, открывший программу по адресу 192.168.x.x:8091, приходит с собственного
// LAN-адреса ПК — его надо пускать (Alex TG 20083); чужое устройство и link-local IPv6 с зоной — нет.
func TestLocalOnlyAllowsOwnLANAddress(t *testing.T) {
	var own string
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && !n.IP.IsLoopback() && n.IP.To4() != nil {
			own = n.IP.String()
			break
		}
	}
	if own == "" {
		t.Skip("у этого ПК нет своего IPv4-адреса кроме петли")
	}
	for addr, want := range map[string]bool{
		own + ":54321":                  true,  // свой LAN-адрес
		"127.0.0.1:1":                   true,  // петля
		"[fe80::dead:beef%Ethernet]:55": false, // чужой link-local с зоной
		"203.0.113.9:55":                false, // чужой публичный
	} {
		if got := isThisComputer(addr); got != want {
			t.Errorf("isThisComputer(%q) = %v, ждали %v", addr, got, want)
		}
	}
	// и через сам обработчик: с собственного адреса команда проходит
	called := false
	req := httptest.NewRequest("POST", "/x", nil)
	req.RemoteAddr = own + ":54321"
	rec := httptest.NewRecorder()
	localOnly(func(w http.ResponseWriter, r *http.Request) { called = true })(rec, req)
	if rec.Code != 200 || !called {
		t.Errorf("с собственного адреса %s команда должна проходить: код %d, вызвана %v", own, rec.Code, called)
	}
}

// Отказ называет адрес, с которого пришёл запрос, — по фото ошибки видно, кого именно не пустили.
func TestLocalOnlyDenialNamesTheAddress(t *testing.T) {
	req := httptest.NewRequest("POST", "/x", nil)
	req.RemoteAddr = "203.0.113.9:5555"
	rec := httptest.NewRecorder()
	localOnly(func(w http.ResponseWriter, r *http.Request) {})(rec, req)
	if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "203.0.113.9") {
		t.Errorf("код %d, тело %q", rec.Code, rec.Body.String())
	}
}

func TestOpenFolderRejectsForeignPaths(t *testing.T) {
	var opened []string
	old := openFolderFn
	openFolderFn = func(p string) error { opened = append(opened, p); return nil }
	defer func() { openFolderFn = old }()
	e := ctxFixture(t)
	e.addSong(t, "t1", "HitZone/01.mp3", "x")
	post := func(path string) int {
		b, _ := json.Marshal(map[string]string{"path": path})
		rec := httptest.NewRecorder()
		e.s.hOpenFolder(rec, httptest.NewRequest("POST", "/api/open-folder", strings.NewReader(string(b))))
		return rec.Code
	}
	if c := post(`C:\Windows`); c != http.StatusForbidden {
		t.Errorf("чужая папка: ждали 403, получили %d", c)
	}
	if c := post(`C:\`); c != http.StatusForbidden {
		t.Errorf("корень диска: ждали 403, получили %d", c)
	}
	if c := post(filepath.Join(e.root, "HitZone") + `" & calc.exe & "`); c != http.StatusForbidden {
		t.Errorf("путь с кавычкой: ждали 403, получили %d", c)
	}
	if len(opened) != 0 {
		t.Errorf("чужие пути не должны доходить до проводника: %v", opened)
	}
	if c := post(filepath.Join(e.root, "HitZone")); c != http.StatusOK || len(opened) != 1 {
		t.Errorf("своя папка: ждали 200 и один запуск, получили %d / %v", c, opened)
	}
	inLib, err := e.s.pathInLibrary(strings.ToUpper(filepath.Join(e.root, "hitzone"))) // регистр не важен
	if err != nil || !inLib {
		t.Errorf("папка из каталога должна быть признана (регистр не важен): %v %v", inLib, err)
	}
	if inLib, _ := e.s.pathInLibrary(filepath.Join(e.root, "HitZ")); inLib {
		t.Errorf("«HitZ» — не папка каталога, а начало имени")
	}
}

func TestPruneEmptyDirs(t *testing.T) {
	root := t.TempDir()
	deep := filepath.Join(root, "a", "b", "c")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(root, "a", "x")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(other, "f.txt"), []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	pruneEmptyDirs([]string{deep}, nil)
	if _, err := os.Stat(filepath.Join(root, "a", "b")); !os.IsNotExist(err) {
		t.Errorf("b и c пустые — должны исчезнуть")
	}
	if _, err := os.Stat(filepath.Join(root, "a")); err != nil {
		t.Errorf("a не пуста (в ней x) — должна остаться: %v", err)
	}
	// папку-источник не трогаем
	src := filepath.Join(root, "src")
	if err := os.MkdirAll(filepath.Join(src, "d"), 0o755); err != nil {
		t.Fatal(err)
	}
	pruneEmptyDirs([]string{filepath.Join(src, "d")}, []string{src})
	if _, err := os.Stat(src); err != nil {
		t.Errorf("папка-источник должна остаться: %v", err)
	}
	if _, err := os.Stat(filepath.Join(src, "d")); !os.IsNotExist(err) {
		t.Errorf("пустая d должна исчезнуть")
	}
}

func TestRevealHandler(t *testing.T) {
	var got []string
	old := revealFn
	revealFn = func(p string) error { got = append(got, p); return nil }
	defer func() { revealFn = old }()
	e := ctxFixture(t)
	f := e.addSong(t, "t1", "A/01.mp3", "x")
	e.addSong(t, "t2", "A/gone.mp3", "") // файла на диске нет

	call := func(body string) int {
		rec := httptest.NewRecorder()
		e.s.hReveal(rec, httptest.NewRequest("POST", "/api/reveal", strings.NewReader(body)))
		return rec.Code
	}
	if c := call(`{"track_id":"t1"}`); c != 200 || len(got) != 1 || got[0] != f {
		t.Errorf("t1: код %d, запуски %v (ждали один запуск с %s)", c, got, f)
	}
	if c := call(`{"track_id":"t2"}`); c != http.StatusNotFound {
		t.Errorf("файла нет: ждали 404, получили %d", c)
	}
	if c := call(`{"track_id":"нет"}`); c != http.StatusNotFound {
		t.Errorf("песни нет: ждали 404, получили %d", c)
	}
	if c := call(`{}`); c != http.StatusBadRequest {
		t.Errorf("пустое тело: ждали 400, получили %d", c)
	}
	if len(got) != 1 {
		t.Errorf("проводник должен запуститься ровно один раз: %v", got)
	}
}

func TestSkipScanDir(t *testing.T) {
	for name, want := range map[string]bool{"_deleted": true, "_DELETED": true, "музыка": false, "deleted": false, "_backup": false} {
		if got := skipScanDir(name); got != want {
			t.Errorf("skipScanDir(%q) = %v, ждали %v", name, got, want)
		}
	}
}
