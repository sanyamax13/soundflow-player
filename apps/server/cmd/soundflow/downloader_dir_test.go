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
