package pathmap

import (
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

func pathEqual(a, b string) bool {
	return filepath.Clean(a) == filepath.Clean(b)
}
