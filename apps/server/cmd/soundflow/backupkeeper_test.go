package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestBackupKeeperMakesDailyAndPrunes(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "_backup")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// 8 старых ночных копий и одна «перед уборкой» — её не трогаем.
	old := time.Now().Add(-48 * time.Hour)
	for i := 1; i <= 8; i++ {
		p := filepath.Join(dir, "soundflow-2026090"+string(rune('0'+i))+"-030000-nightly.db")
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		_ = os.Chtimes(p, old, old)
	}
	other := filepath.Join(dir, "soundflow-20260901-000000-before-reconcile.db")
	_ = os.WriteFile(other, []byte("x"), 0o644)

	made := 0
	k := &backupKeeper{s: &Service{dbPath: filepath.Join(root, "soundflow.db")}, now: time.Now}
	k.make = func() (string, error) {
		made++
		p := filepath.Join(dir, "soundflow-20260926-030000-nightly.db")
		return p, os.WriteFile(p, []byte("new"), 0o644)
	}

	k.once()
	if made != 1 {
		t.Fatalf("copy must be made when last is >24h old, made=%d", made)
	}
	if n := len(nightlyBackups(dir)); n != backupKeepNightly {
		t.Fatalf("keep %d nightly, have %d", backupKeepNightly, n)
	}
	if _, err := os.Stat(other); err != nil {
		t.Fatal("non-nightly backup must stay")
	}
	k.once() // свежая есть — вторую не делаем
	if made != 1 {
		t.Fatalf("second copy within a day, made=%d", made)
	}
}
