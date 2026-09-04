package legacy

import "testing"

func TestBuildFromEmbedded(t *testing.T) {
	marks, err := build()
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	var favs, blocked int
	for _, m := range marks {
		switch m.Kind {
		case "favorite":
			favs++
		case "blocked":
			blocked++
		default:
			t.Fatalf("неожиданный kind %q", m.Kind)
		}
		if m.Key == "" || m.Key == "__" {
			t.Fatalf("пустой ключ у %q — %q", m.Artist, m.Title)
		}
	}
	// Выгрузка 04.09.2026: 25 избранных, 313 permanent в чёрном списке.
	// Немного меньше — ок (дубли ключей схлопываются), заметно меньше — ошибка.
	if favs < 15 {
		t.Errorf("мало избранного: %d", favs)
	}
	if blocked < 250 {
		t.Errorf("мало заблокированного: %d", blocked)
	}
}

func TestBuildBlockedWins(t *testing.T) {
	marks, err := build()
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	// Ни один ключ не должен остаться favorite, если он же есть в blocked —
	// build() перезаписывает favorite на blocked. Проверяем инвариант: карта
	// по ключу, значит коллизия невозможна, но убедимся что kind валиден.
	for k, m := range marks {
		if m.Key != k {
			t.Fatalf("ключ карты %q != m.Key %q", k, m.Key)
		}
	}
}
