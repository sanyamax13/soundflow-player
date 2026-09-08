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
