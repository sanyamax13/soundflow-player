package main

import "testing"

// Одиночные найденные песни качалка кладёт в отдельную папку «Яндекс»
// (Alex TG 20060), а не россыпью папок исполнителей по корню коллекции.
func TestTrackCacheDirDefaultIsYandexFolder(t *testing.T) {
	t.Setenv("SOUNDFLOW_TRACK_CACHE_DIR", "")
	if got, want := trackCacheDir(), `G:\Музыка\Яндекс`; got != want {
		t.Fatalf("trackCacheDir() = %q, want %q", got, want)
	}
}

func TestTrackCacheDirEnvOverride(t *testing.T) {
	t.Setenv("SOUNDFLOW_TRACK_CACHE_DIR", `D:\другое`)
	if got := trackCacheDir(); got != `D:\другое` {
		t.Fatalf("env override ignored: %q", got)
	}
}

// Торрент-альбомы — на диск G, в подпапку «Торренты» папки с музыкой (Alex TG 20228).
func TestAlbumsDirDefaultIsOnDriveG(t *testing.T) {
	t.Setenv("SOUNDFLOW_ALBUMS_DIR", "")
	if got, want := albumsDir(), `G:\Музыка\Торренты`; got != want {
		t.Fatalf("albumsDir() = %q, want %q", got, want)
	}
}

func TestAlbumsDirEnvOverride(t *testing.T) {
	t.Setenv("SOUNDFLOW_ALBUMS_DIR", `D:\альбомы`)
	if got := albumsDir(); got != `D:\альбомы` {
		t.Fatalf("env override ignored: %q", got)
	}
}

// Альбомы одного исполнителя — прямо в папку исполнителя корня музыки, без «Торренты» (Alex TG 20295, вариант «2»).
func TestAlbumsArtistRootDefaultIsMusicRoot(t *testing.T) {
	t.Setenv("SOUNDFLOW_ALBUMS_DIR", "")
	t.Setenv("SOUNDFLOW_ALBUMS_ARTIST_ROOT", "")
	if got, want := albumsArtistRoot(), `G:\Музыка`; got != want {
		t.Fatalf("albumsArtistRoot() = %q, want %q", got, want)
	}
}

// Папку альбомов переопределили, а корень не задан — корень музыки неизвестен: раскладка выключена, всё по-старому.
func TestAlbumsArtistRootOffWhenAlbumsDirOverridden(t *testing.T) {
	t.Setenv("SOUNDFLOW_ALBUMS_DIR", `D:\альбомы`)
	t.Setenv("SOUNDFLOW_ALBUMS_ARTIST_ROOT", "")
	if got := albumsArtistRoot(); got != "" {
		t.Fatalf("раскладка должна быть выключена, а корень = %q", got)
	}
}

func TestAlbumsArtistRootEnvOverride(t *testing.T) {
	t.Setenv("SOUNDFLOW_ALBUMS_DIR", `D:\альбомы`)
	t.Setenv("SOUNDFLOW_ALBUMS_ARTIST_ROOT", `D:\музыка`)
	if got := albumsArtistRoot(); got != `D:\музыка` {
		t.Fatalf("env override ignored: %q", got)
	}
}
