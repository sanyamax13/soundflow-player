package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"syscall"
	"time"
)

// downloaderProc — менеджер дочернего процесса «качалки» (Python, apps/
// downloader). Держим её живой рядом с SoundFlow: старт при запуске, стоп при
// выходе, перезапуск при падении. Слушает 127.0.0.1 на свободном порту.
//
// Нет папки качалки / venv — не беда: acquire («Найти трек») останется
// выключенным (503), всё остальное — каталог, плеер, синхронизация — работает.
type downloaderProc struct {
	dir    string // apps/downloader (есть .venv и src/main.py)
	python string // .venv/Scripts/python.exe

	mu      sync.Mutex
	cmd     *exec.Cmd
	port    int
	baseURL string
	ready   bool

	stop chan struct{}
}

// trackCacheDir — куда качалка сохраняет одиночные найденные треки.
func trackCacheDir() string {
	if v := os.Getenv("SOUNDFLOW_TRACK_CACHE_DIR"); v != "" {
		return v
	}
	return `G:\Музыка`
}

// findDownloaderDir — где лежит качалка. env SOUNDFLOW_DOWNLOADER → рядом с exe
// (downloader/) → apps/downloader от рабочей папки (dev). "" — не нашли.
func findDownloaderDir() string {
	cands := []string{os.Getenv("SOUNDFLOW_DOWNLOADER")}
	if ed := exeDir(); ed != "" {
		cands = append(cands, filepath.Join(ed, "downloader"))
	}
	if wd, err := os.Getwd(); err == nil {
		cands = append(cands,
			filepath.Join(wd, "apps", "downloader"),
			filepath.Join(wd, "..", "..", "apps", "downloader"),
		)
	}
	for _, c := range cands {
		if c == "" {
			continue
		}
		if fi, err := os.Stat(filepath.Join(c, "src", "main.py")); err == nil && !fi.IsDir() {
			abs, _ := filepath.Abs(c)
			return abs
		}
	}
	return ""
}

func newDownloaderProc() *downloaderProc {
	dir := findDownloaderDir()
	if dir == "" {
		return nil
	}
	py := filepath.Join(dir, ".venv", "Scripts", "python.exe")
	if runtime.GOOS != "windows" {
		py = filepath.Join(dir, ".venv", "bin", "python")
	}
	if _, err := os.Stat(py); err != nil {
		fmt.Printf("SoundFlow: качалка найдена (%s), но нет venv (%s) — «Найти трек» выключено\n", dir, py)
		return nil
	}
	return &downloaderProc{dir: dir, python: py, stop: make(chan struct{})}
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// run — запустить и держать живой (перезапуск при выходе). Блокирует; звать в горутине.
func (d *downloaderProc) run() {
	for {
		select {
		case <-d.stop:
			return
		default:
		}
		if err := d.startOnce(); err != nil {
			fmt.Printf("SoundFlow: качалка не поднялась: %v (повтор через 15 с)\n", err)
		}
		// startOnce вернулся — процесс завершился. Пауза и перезапуск.
		d.mu.Lock()
		d.ready = false
		d.mu.Unlock()
		select {
		case <-d.stop:
			return
		case <-time.After(15 * time.Second):
		}
	}
}

func (d *downloaderProc) startOnce() error {
	port, err := freePort()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cmd := exec.CommandContext(ctx, d.python, "-m", "uvicorn", "src.main:app",
		"--host", "127.0.0.1", "--port", strconv.Itoa(port))
	cmd.Dir = d.dir
	cmd.Env = append(os.Environ(),
		"SIDECAR_PORT="+strconv.Itoa(port),
		"SIDECAR_HOST=127.0.0.1",
		"PYTHONIOENCODING=utf-8",
		// Куда качалка кладёт найденные по одному треки (Яндекс/musify/
		// mp3party — «Найти и скачать», авто-докачка лайков). Раньше — свой
		// внутренний E:\soundflow-data\cache плоским списком «yandex-12345.
		// mp3» без имени. Alex TG 15.09.2026: хочет как остальную музыку —
		// на диск G, по папкам исполнителей, не мешать с диском C (там и так
		// места мало). Дефолт — под переопределение своим SOUNDFLOW_TRACK_
		// CACHE_DIR, если у кого-то G: не диск с музыкой.
		"TRACK_CACHE_DIR=" + trackCacheDir(),
	)
	// Лог качалки — рядом с ней, перезаписываем при старте. Нужен, когда
	// что-то не качается: окно консоли скрыто, иначе диагностики нет.
	if lf, err := os.Create(filepath.Join(d.dir, "downloader.log")); err == nil {
		cmd.Stdout, cmd.Stderr = lf, lf
		defer lf.Close()
	}
	hideChildWindow(cmd)

	if err := cmd.Start(); err != nil {
		return err
	}
	d.mu.Lock()
	d.cmd, d.port, d.baseURL, d.ready = cmd, port, fmt.Sprintf("http://127.0.0.1:%d", port), false
	d.mu.Unlock()

	// Ждём /health (до 40 с).
	if d.waitHealth(port, 40*time.Second) {
		d.mu.Lock()
		d.ready = true
		d.mu.Unlock()
		fmt.Printf("SoundFlow: качалка на 127.0.0.1:%d\n", port)
	} else {
		fmt.Printf("SoundFlow: качалка не ответила на /health за 40 с — убиваю, повтор\n")
		cancel()
	}

	// Ждём завершения процесса (штатного или после cancel / d.stop).
	go func() {
		<-d.stop
		cancel()
	}()
	_ = cmd.Wait()
	return nil
}

func (d *downloaderProc) waitHealth(port int, timeout time.Duration) bool {
	cl := &http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(timeout)
	url := fmt.Sprintf("http://127.0.0.1:%d/health", port)
	for time.Now().Before(deadline) {
		select {
		case <-d.stop:
			return false
		default:
		}
		if resp, err := cl.Get(url); err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return true
			}
		}
		time.Sleep(700 * time.Millisecond)
	}
	return false
}

// downloaderState — честная причина, почему «Найти и скачать»/торренты
// недоступны (Опус-ревью 14.09.2026, пункт 3): вкладка раньше вечно писала
// «качалка ещё запускается», хотя на установленной копии (папки apps/
// downloader рядом с exe нет — инсталлятор её не кладёт) она вообще никогда
// не появится. permanent=true — качалки нет в этой копии программы и она не
// появится за этот запуск; permanent=false — есть, но ещё поднимается или
// перезапускается после сбоя (сообщение может стать неактуальным само).
func (s *Service) downloaderState() (ready, permanent bool, reason string) {
	if url := s.sidecarURL(); url != "" {
		return true, false, ""
	}
	if s.dl == nil {
		return false, true, "качалка не входит в эту копию программы — скачивание одного трека и через торренты недоступно"
	}
	return false, false, "качалка ещё запускается — попробуй через минуту"
}

// URL — базовый адрес качалки, если она сейчас готова. "" — не готова.
func (d *downloaderProc) URL() string {
	if d == nil {
		return ""
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.ready {
		return d.baseURL
	}
	return ""
}

func (d *downloaderProc) shutdown() {
	if d == nil {
		return
	}
	select {
	case <-d.stop:
	default:
		close(d.stop)
	}
}

// qBittorrentReachable — только проверка, без запуска (Опус-ревью
// 14.09.2026, пункт 9): смотрим, отвечает ли Web UI qBittorrent на :8080.
// Нужна, чтобы предупредить в окне ДО того, как Alex откроет вкладку
// торрентов и попробует скачать — раньше об отсутствии qBittorrent узнавали
// только по ошибке после неудачной попытки.
func qBittorrentReachable() bool {
	cl := &http.Client{Timeout: 2 * time.Second}
	resp, err := cl.Get("http://127.0.0.1:8080/")
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

// ensureQBittorrent — торрент-режиму нужен запущенный qBittorrent с включённым
// Web UI (порт 8080, логин из downloader/.env). Если порт молчит — пробуем
// запустить qbittorrent.exe. Web UI и пароль пользователь настраивает в самом
// qBittorrent один раз (Настройки → Web UI).
func ensureQBittorrent() error {
	if qBittorrentReachable() {
		return nil
	}
	exe := ""
	for _, c := range []string{
		os.Getenv("SOUNDFLOW_QBITTORRENT"),
		`C:\Program Files\qBittorrent\qbittorrent.exe`,
		`C:\Program Files (x86)\qBittorrent\qbittorrent.exe`,
	} {
		if c != "" {
			if _, err := os.Stat(c); err == nil {
				exe = c
				break
			}
		}
	}
	if exe == "" {
		return fmt.Errorf("qBittorrent не найден — поставь его для торрент-режима")
	}
	cmd := exec.Command(exe)
	if runtime.GOOS == "windows" {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("не смог запустить qBittorrent: %w", err)
	}
	// Дать Web UI подняться.
	cl := &http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if resp, err := cl.Get("http://127.0.0.1:8080/"); err == nil {
			resp.Body.Close()
			return nil
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("qBittorrent запущен, но Web UI на :8080 не ответил — включи Web UI в настройках qBittorrent")
}

// hideChildWindow — не показывать консольное окно дочернего python на Windows.
func hideChildWindow(cmd *exec.Cmd) {
	if runtime.GOOS != "windows" {
		return
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: 0x08000000, // CREATE_NO_WINDOW
	}
}
