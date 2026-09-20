package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// В тестах файлы создаются прямо перед сканом — «свежесть» отключаем; отдельный тест включает её обратно.
func init() { scanFreshFor = 0 }

// Свежий (ещё пишущийся) файл скан пропускает и не добавляет в каталог; когда он «остыл» — добавляет.
func TestScanSkipsFreshFilesUntilTheyCoolDown(t *testing.T) {
	old := scanFreshFor
	t.Cleanup(func() { scanFreshFor = old })

	e := ctxFixture(t)
	e.s.jobs = NewJobRunner(e.s)
	e.s.recon = nil
	dir := filepath.Join(e.root, "Артист - Альбом")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "01 Артист - Песня.mp3")
	if err := os.WriteFile(file, []byte("not really mp3"), 0o644); err != nil {
		t.Fatal(err)
	}

	scanFreshFor = time.Hour // файл только что создан — свежий
	e.s.jobs.StartScan(e.root)
	j := waitScan(t, e.s)
	if j.Total != 0 || trackCount(t, e.s) != 0 {
		t.Fatalf("свежий файл не должен участвовать в скане: total=%d, песен %d", j.Total, trackCount(t, e.s))
	}

	past := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(file, past, past); err != nil {
		t.Fatal(err)
	}
	e.s.jobs.StartScan(e.root)
	j = waitScan(t, e.s)
	if j.Total != 1 {
		t.Fatalf("остывший файл должен попасть в скан: total=%d", j.Total)
	}
}
