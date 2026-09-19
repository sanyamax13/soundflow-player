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
