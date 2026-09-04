package pathmap

import (
	"os"
	"path/filepath"
	"testing"
)

func TestToLocal(t *testing.T) {
	m := New(
		Pair{Canonical: `E:\soundflow-data\cache`, Local: `D:\SoundFlow\cache`},
		Pair{Canonical: `E:\soundflow-data\music`, Local: `D:\SoundFlow\music`},
	)
	cases := []struct{ in, want string }{
		{`E:\soundflow-data\cache\Kino - Gruppa krovi.mp3`, `D:\SoundFlow\cache\Kino - Gruppa krovi.mp3`},
		{`E:\soundflow-data\music\Album\01.mp3`, `D:\SoundFlow\music\Album\01.mp3`},
		{`E:\soundflow-data\cache`, `D:\SoundFlow\cache`},
		// регистр корня не важен
		{`e:\SOUNDFLOW-DATA\cache\x.mp3`, `D:\SoundFlow\cache\x.mp3`},
		// вне известных корней — как есть
		{`C:\other\file.mp3`, `C:\other\file.mp3`},
		{``, ``},
	}
	for _, c := range cases {
		got := m.ToLocal(c.in)
		if !pathEqual(got, c.want) {
			t.Errorf("ToLocal(%q) = %q, ждал %q", c.in, got, c.want)
		}
	}
}

func TestToCanonical(t *testing.T) {
	m := New(
		Pair{Canonical: `E:\soundflow-data\cache`, Local: `D:\SoundFlow\cache`},
		Pair{Canonical: `E:\soundflow-data\music`, Local: `D:\SoundFlow\music`},
	)
	cases := []struct{ in, want string }{
		{`D:\SoundFlow\cache\Kino - Gruppa krovi.mp3`, `E:\soundflow-data\cache\Kino - Gruppa krovi.mp3`},
		{`D:\SoundFlow\music\Album\01.mp3`, `E:\soundflow-data\music\Album\01.mp3`},
		{`C:\other\file.mp3`, `C:\other\file.mp3`},
		{``, ``},
	}
	for _, c := range cases {
		got := m.ToCanonical(c.in)
		if !pathEqual(got, c.want) {
			t.Errorf("ToCanonical(%q) = %q, ждал %q", c.in, got, c.want)
		}
	}
	// туда-обратно — исходный путь
	local := `D:\SoundFlow\cache\x.mp3`
	if got := m.ToLocal(m.ToCanonical(local)); !pathEqual(got, local) {
		t.Errorf("round-trip: получил %q", got)
	}
}

func TestToLocalNoop(t *testing.T) {
	// пары не заданы → путь не меняется
	m := New()
	in := `E:\soundflow-data\cache\x.mp3`
	if got := m.ToLocal(in); got != in {
		t.Errorf("без пар должно быть no-op, получил %q", got)
	}
	// пара где canonical == local
	m2 := New(Pair{Canonical: `D:\SoundFlow\cache`, Local: `D:\SoundFlow\cache`})
	if got := m2.ToLocal(`D:\SoundFlow\cache\x.mp3`); !pathEqual(got, `D:\SoundFlow\cache\x.mp3`) {
		t.Errorf("canonical==local: получил %q", got)
	}
}

// MoveToTrash + RestoreFromTrash — «Корзина»: убрал, потом вернул, файл цел
// на исходном месте, в _trash пусто.
func TestMoveToTrashAndRestore(t *testing.T) {
	root := t.TempDir()
	m := New(Pair{Canonical: `E:\canon`, Local: root})
	local := filepath.Join(root, "sub", "Song.mp3")
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(local, []byte("audio"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	if err := MoveToTrash(m, local); err != nil {
		t.Fatalf("MoveToTrash: %v", err)
	}
	if _, err := os.Stat(local); !os.IsNotExist(err) {
		t.Fatalf("исходный файл должен исчезнуть: %v", err)
	}
	trashed := filepath.Join(root, "_trash", "sub", "Song.mp3")
	if _, err := os.Stat(trashed); err != nil {
		t.Fatalf("файл должен оказаться в _trash: %v", err)
	}

	if err := RestoreFromTrash(m, local); err != nil {
		t.Fatalf("RestoreFromTrash: %v", err)
	}
	if _, err := os.Stat(local); err != nil {
		t.Errorf("файл должен вернуться на место: %v", err)
	}
	if _, err := os.Stat(trashed); !os.IsNotExist(err) {
		t.Errorf("в _trash не должно остаться копии: %v", err)
	}
}

// Ничего не лежит в корзине — понятная ошибка, не паника и не тихий успех.
func TestRestoreFromTrashNothingThere(t *testing.T) {
	root := t.TempDir()
	m := New(Pair{Canonical: `E:\canon`, Local: root})
	if err := RestoreFromTrash(m, filepath.Join(root, "Ghost.mp3")); err == nil {
		t.Error("ждал ошибку — в корзине ничего нет")
	}
}

func pathEqual(a, b string) bool {
	return filepath.Clean(a) == filepath.Clean(b)
}
