package coverart

import "testing"

func TestEmbeddedMissingFile(t *testing.T) {
	if _, _, ok := Embedded(`E:\this-file-does-not-exist-x7q9.mp3`); ok {
		t.Error("несуществующий файл — обложки быть не должно")
	}
}

func TestEmbeddedNotAudioFile(t *testing.T) {
	// Существующий файл без тегов (сам исходник пакета) — теги не читаются,
	// обложки нет. Проверяем, что это не паника и не ложное "нашли".
	if _, _, ok := Embedded("coverart.go"); ok {
		t.Error("обычный текстовый файл — обложки быть не должно")
	}
}
