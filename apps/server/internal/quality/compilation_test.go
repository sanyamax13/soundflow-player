package quality

import (
	"path/filepath"
	"testing"
)

func TestLooksLikeNumberedAlbum(t *testing.T) {
	cases := []struct {
		name  string
		files []string
		want  bool
	}{
		{"два диска Dance Hits", []string{"01. Deja Vu - Unbreak My Heart.mp3", "02. T-Spoon - Tom's Party.mp3", "03. Heart Attack - X.mp3", "04. DJ Vertigo - Oxygene.mp3"}, true},
		{"без пробела после точки", []string{"1.Captain Jack - Another one.mp3", "2.Scatman John - Invisible Man.mp3", "3.Mr.President - A Kind Of Magic.mp3"}, true},
		{"номер через пробел", []string{"01 Vengaboys - Boom.mp3", "02 Dru Hill - How Deep.mp3", "03 Cardigans - Game.mp3"}, true},
		{"подчёркивание", []string{"05_Mike - A.mp3", "06_Dr Alban - B.mp3", "07_Adam - C.mp3"}, true},
		{"часть песен из диска — номера не подряд", []string{"08 A - x.mp3", "09 B - y.mp3", "13 C - z.mp3"}, true},
		{"папка исполнителя 25_17: одно и то же число", []string{"25_17 - Звезда.mp3", "25_17 - Жду чуда.mp3", "25_17 - Остаться.mp3", "25_17 - Голова.mp3"}, false},
		{"мало файлов", []string{"01. A - x.mp3", "02. B - y.mp3"}, false},
		{"обычные имена без номеров", []string{"Звери - Районы.mp3", "Звери - Напитки.mp3", "Звери - Всё.mp3"}, false},
		{"номера у меньшинства", []string{"01. A - x.mp3", "02. B - y.mp3", "03. C - z.mp3", "Rammstein - Du Hast.mp3", "Queen - Radio.mp3", "Muse - Uprising.mp3", "Sting - Fields.mp3"}, false},
		{"пусто", nil, false},
	}
	for _, c := range cases {
		if got := LooksLikeNumberedAlbum(c.files); got != c.want {
			t.Errorf("%s: LooksLikeNumberedAlbum = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestAlbumFromFolder(t *testing.T) {
	root := filepath.Join("G:", string(filepath.Separator), "Музыка")
	j := func(parts ...string) string { return filepath.Join(append([]string{root}, parts...)...) }
	cases := []struct{ dir, want string }{
		{j("Queen Dance Traxx"), "Queen Dance Traxx"},
		// заглушка вместо названия → родительская папка
		{j("Dance Hits 90s - Best Remixes Of Hits 70s-80s", "Album Artist - Album cd1"), "Dance Hits 90s - Best Remixes Of Hits 70s-80s"},
		{j("Dance Hits 90s - Best Remixes Of Hits 70s-80s", "Album Artist - Album cd2"), "Dance Hits 90s - Best Remixes Of Hits 70s-80s"},
		// хвосты в скобках срезаем
		{j("HitZone", "Hitzone 72 (2CD, 2015) [FLAC Rip]", "CD 1"), "Hitzone 72"},
		{j("HitZone", "Hitzone 72 (2CD, 2015) [FLAC Rip]", "CD 2"), "Hitzone 72"},
		{j("HitZone", "Hitzone Gold (3 CD, 2009) [320]", "CD3"), "Hitzone Gold"},
		{j("HitZone", "Hitzone Gold (3 CD, 2009) [320]"), "Hitzone Gold"},
		{j("Best Of", "Диск 2"), "Best Of"},
		// рекламный хвост качалки не должен попасть в имя альбома
		{j("Dance Mix [mp3xa.cc]"), "Dance Mix"},
		// «Disco» — не «Disc» + число: папку заглушкой не считаем
		{j("Disco 80"), "Disco 80"},
	}
	for _, c := range cases {
		if got := AlbumFromFolder(c.dir); got != c.want {
			t.Errorf("AlbumFromFolder(%q) = %q, want %q", c.dir, got, c.want)
		}
	}
}
