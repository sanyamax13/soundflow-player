package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Программа сама раз в сутки делает копию БАЗЫ (26.09.2026, общий вывод пяти разборов SoundFlow,
// Alex «делай»: единственная точка отказа — диск сервера; в базе вкус, отпечатки, история, метки —
// их не восстановить). Копия — VACUUM INTO в <папка_базы>/_backup/soundflow-ГГГГММДД-ЧЧММСС-nightly.db,
// хранятся последние backupKeepNightly; копии «перед уборкой» (другие метки) не трогает.
// Музыкальные файлы не копирует (Alex TG 21860: «музыку не держишь копию»).
// Копию на VDS забирает отдельный таймер системы (deploy/soundflow-db-offsite).
const (
	backupFirstDelay  = 10 * time.Minute
	backupCheckEvery  = time.Hour
	backupInterval    = 24 * time.Hour
	backupKeepNightly = 7
	backupTag         = "nightly"
)

type backupKeeper struct {
	s      *Service
	cancel context.CancelFunc

	// подменяются в тестах
	delay time.Duration
	every time.Duration
	now   func() time.Time
	make  func() (string, error)
}

func newBackupKeeper(s *Service) *backupKeeper {
	k := &backupKeeper{s: s, delay: backupFirstDelay, every: backupCheckEvery, now: time.Now}
	k.make = func() (string, error) { return s.backupDB(backupTag) }
	return k
}

func (k *backupKeeper) Start() {
	ctx, cancel := context.WithCancel(context.Background())
	k.cancel = cancel
	go k.run(ctx)
}

func (k *backupKeeper) Stop() {
	if k != nil && k.cancel != nil {
		k.cancel()
	}
}

func (k *backupKeeper) dir() string { return filepath.Join(filepath.Dir(k.s.dbPath), "_backup") }

func (k *backupKeeper) run(ctx context.Context) {
	first := time.After(k.delay)
	tick := time.NewTicker(k.every)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-first:
		case <-tick.C:
		}
		k.once()
	}
}

// once — сделать копию, если последней «ночной» больше суток, и убрать лишние старые.
func (k *backupKeeper) once() {
	files := nightlyBackups(k.dir())
	if len(files) > 0 {
		if fi, err := os.Stat(files[len(files)-1]); err == nil && k.now().Sub(fi.ModTime()) < backupInterval-time.Hour {
			return
		}
	}
	p, err := k.make()
	if err != nil {
		log.Printf("копия базы: %v", err)
		_ = writeServerLogSafe("Копия базы не получилась: " + err.Error())
		return
	}
	pruneNightly(k.dir(), backupKeepNightly)
	if fi, err := os.Stat(p); err == nil {
		_ = writeServerLogSafe("Сделана ночная копия базы: " + filepath.Base(p) + " (" + fmtMB(fi.Size()) + ")")
	}
}

func nightlyBackups(dir string) []string {
	ents, _ := os.ReadDir(dir)
	var out []string
	for _, e := range ents {
		n := e.Name()
		if !e.IsDir() && strings.HasPrefix(n, "soundflow-") && strings.HasSuffix(n, "-"+backupTag+".db") {
			out = append(out, filepath.Join(dir, n))
		}
	}
	sort.Strings(out) // в имени дата-время — по алфавиту = по времени
	return out
}

func pruneNightly(dir string, keep int) {
	files := nightlyBackups(dir)
	for i := 0; i < len(files)-keep; i++ {
		_ = os.Remove(files[i])
	}
}

func fmtMB(b int64) string { return fmt.Sprintf("%.0f МБ", float64(b)/(1<<20)) }
