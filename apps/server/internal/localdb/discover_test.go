package localdb

import (
	"path/filepath"
	"testing"
)

func TestDiscoverDismissRoundTrip(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "x.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	if got, err := d.DismissedDiscover(); err != nil || len(got) != 0 {
		t.Fatalf("сначала пусто: %v %v", got, err)
	}
	if err := d.DismissDiscover("a__b", "A", "B"); err != nil {
		t.Fatal(err)
	}
	if err := d.DismissDiscover("a__b", "A", "B"); err != nil { // повторно — не ошибка
		t.Fatal(err)
	}
	if err := d.DismissDiscover("", "", ""); err != nil { // пустой ключ игнорируется
		t.Fatal(err)
	}
	got, _ := d.DismissedDiscover()
	if len(got) != 1 || !got["a__b"] {
		t.Fatalf("скрыто: %v", got)
	}
	if err := d.UndismissDiscover("a__b"); err != nil {
		t.Fatal(err)
	}
	if got, _ := d.DismissedDiscover(); len(got) != 0 {
		t.Fatalf("после «вернуть» пусто: %v", got)
	}
}

// Скрытие не должно задевать чёрную метку «больше не качать» и каталог: это другая таблица.
func TestDiscoverDismissIsSeparateFromBlocked(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "x.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	if err := d.DismissDiscover("a__b", "A", "B"); err != nil {
		t.Fatal(err)
	}
	if blocked, _ := d.IsBlocked("a__b"); blocked {
		t.Fatal("скрытие в «Открытиях» не должно ставить «больше не качать»")
	}
}
