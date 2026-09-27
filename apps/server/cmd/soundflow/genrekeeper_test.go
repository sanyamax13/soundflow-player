package main

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"soundflow/server/internal/localdb"
)

// Круг хранителя жанров: найденный жанр пишется, «не знает» — метка, чтобы не спрашивать снова,
// ошибка связи — песня остаётся «неспрошенной» до следующего круга.
func TestGenreKeeperPass(t *testing.T) {
	db, err := localdb.Open(filepath.Join(t.TempDir(), "g.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, id := range []string{"found", "unknown", "offline"} {
		if _, err := db.SQL().Exec(`INSERT INTO tracks (id, artist, title, normalized_key, genre_tags) VALUES (?, 'A', ?, ?, '[]')`, id, id, "k"+id); err != nil {
			t.Fatal(err)
		}
	}
	k := newGenreKeeper(&Service{db: db})
	k.ask = func(_ context.Context, _, title string) (string, error) {
		switch title {
		case "found":
			return "rusrap", nil
		case "unknown":
			return "", nil
		}
		return "", errors.New("нет сети")
	}
	if err := k.pass(context.Background()); err != nil {
		t.Fatal(err)
	}
	g, _ := db.TrackGenres()
	if g["found"] != "rusrap" || len(g) != 1 {
		t.Fatalf("жанры %+v, ждали только found=rusrap", g)
	}
	need, _ := db.TracksNeedingGenre(10)
	if len(need) != 1 || need[0].ID != "offline" {
		t.Fatalf("неспрошенной должна остаться только offline, осталось %+v", need)
	}
}
