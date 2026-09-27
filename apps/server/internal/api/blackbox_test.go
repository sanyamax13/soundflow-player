package api

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWriteBlackBoxSplitsByDayAndCleans(t *testing.T) {
	root := t.TempDir()
	old := filepath.Join(root, "dev1", "2020-01-01.jsonl")
	if err := os.MkdirAll(filepath.Dir(old), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(old, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	blackBoxCleaned = ""
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	data := []byte(`{"t":"2026-09-25T23:59:59.1","k":"tap"}
{"t":"2026-09-26T00:00:01.2","k":"play"}

{"k":"no-time"}
`)
	n, err := writeBlackBox(root, "dev1", data, now)
	if err != nil || n != 3 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	a, _ := os.ReadFile(filepath.Join(root, "dev1", "2026-09-25.jsonl"))
	b, _ := os.ReadFile(filepath.Join(root, "dev1", "2026-09-26.jsonl"))
	if string(a) != "{\"t\":\"2026-09-25T23:59:59.1\",\"k\":\"tap\"}\n" {
		t.Fatalf("day 25: %q", a)
	}
	if string(b) != "{\"t\":\"2026-09-26T00:00:01.2\",\"k\":\"play\"}\n{\"k\":\"no-time\"}\n" {
		t.Fatalf("day 26: %q", b)
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatalf("old file must be removed, err=%v", err)
	}
	// Вторая пачка дописывается, не затирает.
	if _, err := writeBlackBox(root, "dev1", []byte(`{"t":"2026-09-26T01:00:00","k":"x"}`), now); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(filepath.Join(root, "dev1", "2026-09-26.jsonl"))
	if !strings.HasSuffix(string(b), "{\"k\":\"no-time\"}\n{\"t\":\"2026-09-26T01:00:00\",\"k\":\"x\"}\n") {
		t.Fatalf("append: %q", b)
	}
}
