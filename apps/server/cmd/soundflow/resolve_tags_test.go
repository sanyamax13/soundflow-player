package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Файлы сборников с пустыми тегами: исполнитель и название берутся из имени, а
// номер трека в начале исполнителя срезается (Alex TG 19970). Настоящих mp3 не
// пишем — на не-аудио байтах readTags вернёт пусто, сработает имя файла.
func TestResolveTagsFromFilenameStripsTrackNumber(t *testing.T) {
	cases := []struct{ file, artist, title string }{
		{"01. Deja Vu - Unbreak My Heart.mp3", "Deja Vu", "Unbreak My Heart"},
		{"20. Koko - They Don't Care About Us.mp3", "Koko", "They Don't Care About Us"},
		{"1.Captain Jack - Another one.mp3", "Captain Jack", "Another one"},
		{"12) Adriano Celentano - Uh...Uh.mp3", "Adriano Celentano", "Uh...Uh"},
		// настоящие числа в имени исполнителя не трогаем
		{"50 Cent - In da Club.mp3", "50 Cent", "In da Club"},
		{"2 Unlimited - No Limit.mp3", "2 Unlimited", "No Limit"},
		{"25_17 - Звезда.mp3", "25_17", "Звезда"},
		// без « - » разобрать нечего: исполнителя нет, название — всё имя
		{"NoDelimiter.mp3", "", "NoDelimiter"},
	}
	dir := t.TempDir()
	for _, c := range cases {
		p := filepath.Join(dir, c.file)
		if err := os.WriteFile(p, []byte("not really audio"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
		ar, ti, al := resolveTags(p)
		if ar != c.artist || ti != c.title || al != "" {
			t.Errorf("%q: получил %q / %q / %q, ждал %q / %q / \"\"", c.file, ar, ti, al, c.artist, c.title)
		}
	}
}

// Сборник без тегов: папка с пронумерованными файлами → альбом по имени папки,
// одна плитка на весь сборник. Папка исполнителя с одинаковым числом в имени
// файлов («25_17») сборником не считается.
func TestCompilationAlbumFromFolder(t *testing.T) {
	root := t.TempDir()
	mk := func(dir string, names ...string) string {
		d := filepath.Join(root, filepath.FromSlash(dir))
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		for _, n := range names {
			if err := os.WriteFile(filepath.Join(d, n), []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		return d
	}
	cd1 := mk("Dance Hits 90s/Album Artist - Album cd1", "01. Go Disco - Angie.mp3", "02. Capitan Cozmo - Coundown.mp3", "03. Cosmo-Tom - Shield.mp3", "cover.jpg")
	cd2 := mk("Dance Hits 90s/Album Artist - Album cd2", "01. Deja Vu - Unbreak.mp3", "02. T-Spoon - Party.mp3", "03. Heart Attack - Loving.mp3")
	rap := mk("25_17", "25_17 - Звезда.mp3", "25_17 - Жду чуда.mp3", "25_17 - Остаться.mp3")
	single := mk("Разное", "Sting - Fields.mp3", "Muse - Uprising.mp3")

	cache := map[string]string{}
	cases := []struct{ path, want string }{
		{filepath.Join(cd1, "01. Go Disco - Angie.mp3"), "Dance Hits 90s"},
		{filepath.Join(cd2, "01. Deja Vu - Unbreak.mp3"), "Dance Hits 90s"}, // оба диска — один альбом
		{filepath.Join(rap, "25_17 - Звезда.mp3"), ""},
		{filepath.Join(single, "Sting - Fields.mp3"), ""},
	}
	for _, c := range cases {
		if got := compilationAlbum(cache, c.path); got != c.want {
			t.Errorf("compilationAlbum(%q) = %q, want %q", c.path, got, c.want)
		}
	}
	if len(cache) != 4 {
		t.Errorf("решение по каждой папке помним один раз: в кэше %d записей, ждал 4", len(cache))
	}
}
