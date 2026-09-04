// Package legacy — разовый перенос личной разметки со старого плеера.
// JSON выгружен из старой базы (migration/), вшит в бинарь. При старте, если
// таблица legacy_marks пуста, наполняем её: избранное → kind "favorite",
// перманентный чёрный список → "blocked". Ключ — quality.NormalizedKey, тот же
// что у tracks.normalized_key, поэтому acquire/каталог их сопоставляют.
package legacy

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"time"

	"soundflow/server/internal/db"
	"soundflow/server/internal/quality"
)

//go:embed data/favorites.json
var favoritesJSON []byte

//go:embed data/blacklist.json
var blacklistJSON []byte

type favRow struct {
	Artist  string    `json:"artist"`
	Title   string    `json:"title"`
	LikedAt time.Time `json:"liked_at"`
}

type blRow struct {
	Artist        string    `json:"artist"`
	Title         string    `json:"title"`
	NormalizedKey string    `json:"normalized_key"`
	Kind          string    `json:"kind"`
	BlacklistedAt time.Time `json:"blacklisted_at"`
}

// Seed наполняет legacy_marks из вшитых JSON, если она пуста. Возвращает число
// вставленных строк (0 — уже засеяно или нет базы).
func Seed(ctx context.Context, p *db.Pool) (int, error) {
	if p == nil {
		return 0, nil
	}
	n, err := p.LegacyMarkCount(ctx)
	if err != nil {
		return 0, fmt.Errorf("legacy: проверка таблицы: %w", err)
	}
	if n > 0 {
		return 0, nil
	}

	marks, err := build()
	if err != nil {
		return 0, err
	}
	return p.LegacyMarksInsert(ctx, marks)
}

// build разбирает вшитые JSON в набор меток. blocked побеждает favorite при
// совпадении ключа (карта заполняется favorites, потом перезаписывается blocked).
func build() (map[string]db.LegacyMark, error) {
	marks := make(map[string]db.LegacyMark)

	var favs []favRow
	if err := json.Unmarshal(favoritesJSON, &favs); err != nil {
		return nil, fmt.Errorf("legacy: favorites.json: %w", err)
	}
	for _, f := range favs {
		k := quality.NormalizedKey(f.Artist, f.Title)
		if !validKey(k) {
			continue
		}
		marks[k] = db.LegacyMark{Key: k, Kind: "favorite", Artist: f.Artist, Title: f.Title, At: f.LikedAt}
	}

	var bl []blRow
	if err := json.Unmarshal(blacklistJSON, &bl); err != nil {
		return nil, fmt.Errorf("legacy: blacklist.json: %w", err)
	}
	for _, b := range bl {
		if b.Kind != "permanent" {
			continue // temporary/quick_skip — старые скипы на 14 дней, не переносим
		}
		k := quality.NormalizedKey(b.Artist, b.Title)
		if !validKey(k) {
			k = b.NormalizedKey // запасной вариант — ключ из старой базы
		}
		if !validKey(k) {
			continue
		}
		marks[k] = db.LegacyMark{Key: k, Kind: "blocked", Artist: b.Artist, Title: b.Title, At: b.BlacklistedAt}
	}
	return marks, nil
}

func validKey(k string) bool {
	return k != "" && k != "__"
}
