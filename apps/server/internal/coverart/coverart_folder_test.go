package coverart

import (
	"os"
	"path/filepath"
	"testing"
)

func touch(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("img"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// Картинка рядом с треком — обложка альбома (Alex TG 20146: у 421 песни её нет в файле, но лежит в папке).
func TestFolderImageFindsCoverNextToTrack(t *testing.T) {
	dir := t.TempDir()
	track := filepath.Join(dir, "01 - Song.mp3")
	touch(t, track)
	touch(t, filepath.Join(dir, "Folder.JPG"))
	got, ok := FolderImage(track)
	if !ok || filepath.Base(got) != "Folder.JPG" {
		t.Fatalf("ждал Folder.JPG, получил %q ok=%v", got, ok)
	}
}

// Точное имя сильнее «просто начинается с»: cover.png выигрывает у AlbumArt_{GUID}_Large.jpg.
func TestFolderImageExactNameBeatsPrefix(t *testing.T) {
	dir := t.TempDir()
	track := filepath.Join(dir, "a.mp3")
	touch(t, track)
	touch(t, filepath.Join(dir, "AlbumArt_{ABC}_Large.jpg"))
	touch(t, filepath.Join(dir, "cover.png"))
	got, ok := FolderImage(track)
	if !ok || filepath.Base(got) != "cover.png" {
		t.Fatalf("ждал cover.png, получил %q ok=%v", got, ok)
	}
}

func TestFolderImagePrefixNameCounts(t *testing.T) {
	dir := t.TempDir()
	track := filepath.Join(dir, "a.mp3")
	touch(t, track)
	touch(t, filepath.Join(dir, "AlbumArt_{ABC}_Large.jpg"))
	if got, ok := FolderImage(track); !ok || filepath.Base(got) != "AlbumArt_{ABC}_Large.jpg" {
		t.Fatalf("ждал AlbumArt_{ABC}_Large.jpg, получил %q ok=%v", got, ok)
	}
}

// Чужие картинки (скриншоты, фото исполнителя) и не картинки обложкой не считаем.
func TestFolderImageIgnoresOtherFiles(t *testing.T) {
	dir := t.TempDir()
	track := filepath.Join(dir, "a.mp3")
	touch(t, track)
	touch(t, filepath.Join(dir, "screenshot.jpg"))
	touch(t, filepath.Join(dir, "cover.txt"))
	touch(t, filepath.Join(dir, "artist.png"))
	if got, ok := FolderImage(track); ok {
		t.Fatalf("обложки быть не должно, получил %q", got)
	}
	if _, ok := FolderImage(filepath.Join(dir, "no-such-dir", "a.mp3")); ok {
		t.Fatal("папки нет — обложки быть не должно")
	}
}

func TestFoundCoverByTrackID(t *testing.T) {
	dir := t.TempDir()
	touch(t, filepath.Join(dir, "t_abc.jpg"))
	touch(t, filepath.Join(dir, "t_png.png"))
	if p, ok := Found(dir, "t_abc"); !ok || filepath.Base(p) != "t_abc.jpg" {
		t.Fatalf("t_abc: %q ok=%v", p, ok)
	}
	if p, ok := Found(dir, "t_png"); !ok || filepath.Base(p) != "t_png.png" {
		t.Fatalf("t_png: %q ok=%v", p, ok)
	}
	if _, ok := Found(dir, "t_none"); ok {
		t.Error("для t_none картинки нет")
	}
	if _, ok := Found("", "t_abc"); ok {
		t.Error("папка не задана — не используем")
	}
}

// id приходит из адреса запроса — «../» не должно выводить из папки.
func TestFoundCoverCannotEscapeFolder(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "found")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	touch(t, filepath.Join(root, "secret.jpg"))
	if p, ok := Found(dir, "../secret"); ok {
		t.Fatalf("вышли за папку: %q", p)
	}
}
