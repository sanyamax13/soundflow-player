package diskspace

import (
	"os"
	"testing"
)

func TestFree(t *testing.T) {
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	free, total, err := Free(wd)
	if err != nil {
		t.Fatalf("Free(%q): %v", wd, err)
	}
	if total <= 0 {
		t.Errorf("общий объём диска должен быть > 0, получили %d", total)
	}
	if free < 0 || free > total {
		t.Errorf("свободно %d вне диапазона [0, %d]", free, total)
	}
}
