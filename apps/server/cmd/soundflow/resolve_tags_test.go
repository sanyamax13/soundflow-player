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
