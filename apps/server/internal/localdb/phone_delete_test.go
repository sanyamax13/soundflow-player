package localdb

import (
	"encoding/json"
	"testing"
)

// Удаление с телефона ставит метку «больше не качать» (legacy_marks blocked),
// КРОМЕ причин "bad_quality"/"wrong_version": там сервер ищет замену
// получше, а метка заставила бы acquire отказать («в старом плеере удалён»).
// Так решено с Alex 05.09.2026 (docs/PROGRESS.md, этап 22) и записано в
// api.handleDeleteEvents/deleteAndReacquire.
func TestSaveSyncDeleteBlocksOnlyForTasteReasons(t *testing.T) {
	cases := []struct {
		name    string
		payload string
		blocked bool
	}{
		{"без причины", "", true},
		{"не нравится", `{"reason":"dont_like"}`, true},
		{"плохое качество", `{"reason":"bad_quality"}`, false},
		{"не та версия", `{"reason":"wrong_version"}`, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := open(t)
			if _, err := d.sql.Exec(`INSERT INTO tracks (id, artist, title, normalized_key)
				VALUES ('t1','Artist','Title','artist|title')`); err != nil {
				t.Fatalf("seed track: %v", err)
			}
			ev := SyncEvent{UUID: "u1", Kind: "delete", TrackID: "t1", Payload: json.RawMessage(c.payload), ClientTS: 1}
			if _, err := d.SaveSync(Device{ID: "dev1", Name: "test"}, []SyncEvent{ev}); err != nil {
				t.Fatalf("SaveSync: %v", err)
			}
			var n int
			if err := d.sql.QueryRow(
				`SELECT count(*) FROM legacy_marks WHERE normalized_key='artist|title' AND kind='blocked'`,
			).Scan(&n); err != nil {
				t.Fatalf("count marks: %v", err)
			}
			if got := n == 1; got != c.blocked {
				t.Errorf("blocked = %v; want %v", got, c.blocked)
			}
		})
	}
}
