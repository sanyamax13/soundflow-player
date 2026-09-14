package localdb

import (
	"encoding/json"
	"testing"
	"time"
)

func radioTrack(t *testing.T, d *DB, id, artist string, axis int, jitter float32) {
	t.Helper()
	v := make([]float32, VecDim)
	v[axis] = 1
	v[(axis+3)%VecDim] = jitter
	if _, err := d.sql.Exec(
		`INSERT INTO tracks (id, artist, title, normalized_key, feature_vector) VALUES (?,?,?,?,?)`,
		id, artist, id, id, vecToBlob(v)); err != nil {
		t.Fatal(err)
	}
}

// TestFetchTracksByIDChunking — регрессия на переход с «SELECT по одному id»
// на «SELECT ... WHERE id IN (...)» чанками по 400 (Alex TG 14.09.2026:
// кнопка радио ждала ~10 сек на большой библиотеке — это и был N+1). Больше
// одного чанка (450 id) — граница чанка не должна терять/дублировать записи.
func TestFetchTracksByIDChunking(t *testing.T) {
	d := open(t)
	const n = 450
	ids := make([]string, n)
	for i := 0; i < n; i++ {
		id := "t" + string(rune('a'+i%26)) + string(rune('0'+i/26))
		ids[i] = id
		radioTrack(t, d, id, "artist", i%VecDim, 0)
	}
	// один id без отпечатка (пустой feature_vector) — не должен попасть в out
	if _, err := d.sql.Exec(
		`INSERT INTO tracks (id, artist, title, normalized_key) VALUES (?,?,?,?)`,
		"no-vec", "artist", "no-vec", "no-vec"); err != nil {
		t.Fatal(err)
	}
	out := fetchTracksByID(d.sql, append(append([]string{}, ids...), "no-vec", "missing-entirely"))
	if len(out) != n {
		t.Fatalf("got %d tracks, want %d", len(out), n)
	}
	for _, id := range ids {
		if _, ok := out[id]; !ok {
			t.Errorf("missing id %s across chunk boundary", id)
		}
	}
	if _, ok := out["no-vec"]; ok {
		t.Error("track without fingerprint should be excluded, not just empty vec")
	}
	if _, ok := out["missing-entirely"]; ok {
		t.Error("id absent from table should be excluded")
	}
}

// TestOrderRadioSkipsExactDuplicateOfSeed — регрессия на «одна и та же песня
// попала в очередь как похожая» (Alex TG 14.09.2026, скрин: «Quintino —
// Party Never Ends» / «ALOK, QUINTINO — Party Never Ends», один и тот же
// трек под двумя разными кредитами артиста — проверено на реальном каталоге,
// 20 таких групп с бит-в-бит одинаковым отпечатком). Косинус к себе самому
// (~1.0) не должен попадать в топ «похожего».
func TestOrderRadioSkipsExactDuplicateOfSeed(t *testing.T) {
	d := open(t)
	radioTrack(t, d, "seed", "Seed", 0, 0)
	for i := 0; i < 8; i++ { // minClusterTracks — строим long_term слой
		radioTrack(t, d, "fav"+itoa(i), "Fav"+itoa(i), 0, float32(i)*0.01)
	}
	radioTrack(t, d, "duplicate", "Other Credit", 0, 0) // бит-в-бит тот же вектор, что seed
	radioTrack(t, d, "real_similar", "RealArtist", 0, 0.02)

	var evs []SyncEvent
	for i := 0; i < 8; i++ {
		evs = append(evs, SyncEvent{UUID: "l" + itoa(i), Kind: "like", TrackID: "fav" + itoa(i), Payload: json.RawMessage(``), ClientTS: 1})
	}
	if _, err := d.SaveSync(Device{ID: "d"}, evs); err != nil {
		t.Fatal(err)
	}
	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}

	got, reordered, err := d.OrderRadio("seed", []string{"duplicate", "real_similar"})
	if err != nil {
		t.Fatal(err)
	}
	if !reordered {
		t.Fatal("expected reordered=true")
	}
	if got[0] != "real_similar" {
		t.Errorf("дубликат seed не должен быть топ-похожим, got order %v", got)
	}
}

func TestOrderRadioFallbackNoTaste(t *testing.T) {
	d := open(t)
	radioTrack(t, d, "seed", "S", 0, 0)
	radioTrack(t, d, "a", "A", 0, 0.02)
	radioTrack(t, d, "b", "B", 500, 0.0)
	// центров вкуса нет → OrderRadio должен вести себя как OrderBySimilarity
	got, reordered, err := d.OrderRadio("seed", []string{"b", "a"})
	if err != nil {
		t.Fatal(err)
	}
	want, wr, _ := d.OrderBySimilarity("seed", []string{"b", "a"})
	if !reordered || !wr {
		t.Fatalf("reordered flags: radio=%v sim=%v", reordered, wr)
	}
	if len(got) != len(want) || got[0] != want[0] {
		t.Errorf("radio %v != similarity %v", got, want)
	}
	if got[0] != "a" {
		t.Errorf("closest by sound should be first, got %v", got)
	}
}

func TestOrderRadioTasteAware(t *testing.T) {
	d := open(t)
	// seed и «жанр вкуса» — ось 0; далёкий шум — ось 700. jitter fav начинается
	// с 0.01, НЕ с 0 — иначе fav0 бит-в-бит совпал бы с seed (jitter тоже 0) и
	// после фикса duplicateSimThreshold (14.09.2026) законно ушёл бы в хвост
	// как «тот же трек», а тест здесь проверяет совсем другое — что вкус
	// поднимает реально похожий, но ОТЛИЧНЫЙ от seed трек.
	radioTrack(t, d, "seed", "Seed", 0, 0)
	for i := 0; i < 4; i++ {
		radioTrack(t, d, "fav"+itoa(i), "Fav"+itoa(i), 0, float32(i+1)*0.01)
	}
	// «filler» — ещё 4 лайкнутых трека той же оси, НЕ участвующие в cands
	// ниже: только чтобы добрать minClusterTracks (Task 2), не меняя набор
	// и относительный расклад очков реальных кандидатов теста.
	for i := 0; i < 4; i++ {
		radioTrack(t, d, "filler"+itoa(i), "Filler"+itoa(i), 0, 0.05+float32(i)*0.01)
	}
	// три трека одного нейтрального артиста, близкие по звуку: обычный,
	// недавно пропущенный, и нелюбимого артиста рядом — чтобы правило
	// «≤2 одного артиста подряд» не решало за нас, сравнение по оценке.
	radioTrack(t, d, "n_plain", "Neutral", 0, 0.006)
	radioTrack(t, d, "n_skipped", "Neutral", 0, 0.007)
	radioTrack(t, d, "hated", "HatedArtist", 0, 0.005)
	for i := 0; i < 4; i++ {
		radioTrack(t, d, "far"+itoa(i), "FarArtist"+itoa(i), 700, float32(i)*0.01)
	}

	evs := []SyncEvent{}
	for i := 0; i < 4; i++ {
		evs = append(evs, SyncEvent{UUID: "l" + itoa(i), Kind: "like", TrackID: "fav" + itoa(i), Payload: json.RawMessage(``), ClientTS: 1})
	}
	for i := 0; i < 4; i++ {
		evs = append(evs, SyncEvent{UUID: "lf" + itoa(i), Kind: "like", TrackID: "filler" + itoa(i), Payload: json.RawMessage(``), ClientTS: 1})
	}
	evs = append(evs, SyncEvent{UUID: "dis", Kind: "dislike", TrackID: "hated", Payload: json.RawMessage(``), ClientTS: 1})
	if _, err := d.SaveSync(Device{ID: "d"}, evs); err != nil {
		t.Fatal(err)
	}
	if _, err := d.sql.Exec(
		`INSERT INTO sync_events (event_uuid, device_id, kind, track_id, payload, client_ts, applied_at)
		 VALUES ('sk','d','skip','n_skipped','{}',1,?)`,
		time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}

	cands := []string{"far0", "hated", "n_skipped", "far1", "fav0", "n_plain", "fav1", "far2", "fav2", "fav3", "far3"}
	got, reordered, err := d.OrderRadio("seed", cands)
	if err != nil {
		t.Fatal(err)
	}
	if !reordered {
		t.Fatal("expected reordered")
	}
	if len(got) != len(cands) {
		t.Fatalf("got %d ids, want %d", len(got), len(cands))
	}
	pos := map[string]int{}
	for i, id := range got {
		pos[id] = i
	}
	// звук+вкус: любимый жанр обгоняет «далёкий»
	if pos["fav0"] > pos["far0"] {
		t.Errorf("fav0 (pos %d) should rank above far0 (pos %d)", pos["fav0"], pos["far0"])
	}
	// недавно пропущенный — ниже такого же по звуку непропущенного (тот же артист)
	if pos["n_skipped"] < pos["n_plain"] {
		t.Errorf("n_skipped (pos %d) should rank below n_plain (pos %d)", pos["n_skipped"], pos["n_plain"])
	}
	// нелюбимый артист — ниже нейтрального такого же по звуку
	if pos["hated"] < pos["n_plain"] {
		t.Errorf("hated (pos %d) should rank below n_plain (pos %d)", pos["hated"], pos["n_plain"])
	}
}

// TestOrderRadioNoDuplicatesNoDrops — регрессия на баг слияния антипузыря:
// если far-кандидат оказывался на границе 8-го слота уже пройденным обычным
// ходом по cs, он инъецировался повторно (дубль), а самый низкий по score
// кандидат терялся вовсе. Найдено 13.09.2026 при подключении recent/session
// слоёв (Task 5) — сдвиг шкалы aff подвинул «нелюбимого» кандидата ровно на
// границу и обнажил давнюю ошибку в radio.go, не связанную с самой формулой.
func TestFarThresholdAdaptsToRealDistribution(t *testing.T) {
	// имитация «сжатой» реальной шкалы (0.5..0.95) — фиксированный 0.4
	// не отсекает никого, процентильный обязан отсечь заметную долю
	cs := make([]radioCand, 20)
	for i := range cs {
		cs[i] = radioCand{id: "t" + itoa(i), aff: 0.5 + float64(i)*0.02}
	}
	th := farThreshold(cs)
	if th < 0.4 {
		t.Fatalf("threshold %.3f too low for a compressed 0.5..0.95 distribution", th)
	}
	far := 0
	for _, c := range cs {
		if c.aff < th {
			far++
		}
	}
	if far == 0 {
		t.Error("expected the threshold to actually select some candidates as «far» on this distribution")
	}
	if far == len(cs) {
		t.Error("threshold should not select ALL candidates as «far»")
	}
}

func TestFarThresholdEmptyInput(t *testing.T) {
	if th := farThreshold(nil); th != 0 {
		t.Errorf("empty input should give threshold 0 (nobody qualifies as far), got %v", th)
	}
}

func TestOrderRadioNoDuplicatesNoDrops(t *testing.T) {
	d := open(t)
	radioTrack(t, d, "seed", "Seed", 0, 0)
	for i := 0; i < 8; i++ {
		radioTrack(t, d, "fav"+itoa(i), "Fav"+itoa(i), 0, float32(i)*0.01)
	}
	radioTrack(t, d, "n_plain", "Neutral", 0, 0.006)
	radioTrack(t, d, "hated", "HatedArtist", 0, 0.005)
	for i := 0; i < 4; i++ {
		radioTrack(t, d, "far"+itoa(i), "FarArtist"+itoa(i), 700, float32(i)*0.01)
	}
	var evs []SyncEvent
	for i := 0; i < 8; i++ {
		evs = append(evs, SyncEvent{UUID: "l" + itoa(i), Kind: "like", TrackID: "fav" + itoa(i), Payload: json.RawMessage(``), ClientTS: 1})
	}
	evs = append(evs, SyncEvent{UUID: "dis", Kind: "dislike", TrackID: "hated", Payload: json.RawMessage(``), ClientTS: 1})
	if _, err := d.SaveSync(Device{ID: "d"}, evs); err != nil {
		t.Fatal(err)
	}
	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}

	cands := []string{"far0", "hated", "far1", "fav0", "n_plain", "fav1", "far2", "fav2", "fav3", "far3"}
	got, _, err := d.OrderRadio("seed", cands)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(cands) {
		t.Fatalf("got %d ids, want %d (duplicate or dropped candidate): %v", len(got), len(cands), got)
	}
	seen := map[string]int{}
	for _, id := range got {
		seen[id]++
	}
	for _, id := range cands {
		if seen[id] != 1 {
			t.Errorf("candidate %q appears %d times in result %v; want exactly 1", id, seen[id], got)
		}
	}
}

func TestOrderRadioMatchesOldBehaviorWhenNoRecentOrSession(t *testing.T) {
	d := open(t)
	radioTrack(t, d, "seed", "Seed", 0, 0)
	for i := 0; i < 4; i++ {
		radioTrack(t, d, "fav"+itoa(i), "Fav"+itoa(i), 0, float32(i)*0.01)
	}
	for i := 0; i < 4; i++ {
		radioTrack(t, d, "far"+itoa(i), "Far"+itoa(i), 700, float32(i)*0.01)
	}
	evs := []SyncEvent{}
	for i := 0; i < 4; i++ {
		evs = append(evs, SyncEvent{UUID: "l" + itoa(i), Kind: "like", TrackID: "fav" + itoa(i), Payload: json.RawMessage(``), ClientTS: 1})
	}
	if _, err := d.SaveSync(Device{ID: "d"}, evs); err != nil {
		t.Fatal(err)
	}
	// только long_term построен (4 лайкнутых < порога 8, значит слой НЕ
	// построится вовсе → aff=0 везде → должно совпасть с OrderBySimilarity)
	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}

	cands := []string{"far0", "fav0", "far1", "fav1", "far2", "fav2", "far3", "fav3"}
	got, reordered, err := d.OrderRadio("seed", cands)
	if err != nil {
		t.Fatal(err)
	}
	want, wantReordered, err := d.OrderBySimilarity("seed", cands)
	if err != nil {
		t.Fatal(err)
	}
	if reordered != wantReordered {
		t.Fatalf("reordered mismatch: got %v want %v", reordered, wantReordered)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("order diverged at %d: got %v want %v (full got=%v want=%v)", i, got[i], want[i], got, want)
		}
	}
}

func TestOrderRadioBlendsThreeLayers(t *testing.T) {
	d := open(t)
	radioTrack(t, d, "seed", "Seed", 0, 0)
	// long_term: 8 треков жанра "ось 0" — тот же жанр, что seed
	for i := 0; i < 8; i++ {
		radioTrack(t, d, "old"+itoa(i), "Old"+itoa(i), 0, float32(i)*0.005)
	}
	// recent: 8 треков совсем другого жанра "ось 900" (недавно распробовал)
	for i := 0; i < 8; i++ {
		radioTrack(t, d, "recent"+itoa(i), "Recent"+itoa(i), 900, float32(i)*0.005)
	}
	// кандидат такого же звучания, как recent-жанр, но БЕЗ фидбека сам по себе
	radioTrack(t, d, "cand_recent_genre", "X", 900, 0.02)
	// кандидат далёкого жанра — не пересекается ни с одним слоем
	radioTrack(t, d, "cand_far", "Y", 300, 0)

	var evs []SyncEvent
	for i := 0; i < 8; i++ {
		evs = append(evs, SyncEvent{UUID: "old" + itoa(i), Kind: "like", TrackID: "old" + itoa(i), Payload: json.RawMessage(``), ClientTS: 1})
	}
	if _, err := d.SaveSync(Device{ID: "d"}, evs); err != nil {
		t.Fatal(err)
	}
	if _, _, err := d.RecomputeTasteClusters("long_term", nil); err != nil {
		t.Fatal(err)
	}
	// recent-слой строим из отдельных фидбек-строк (не через SaveSync, чтобы
	// не задеть окно отбора long_term — сценарий "то же самое, но недавно")
	for i := 0; i < 8; i++ {
		if _, err := d.sql.Exec(
			`INSERT INTO feedback_event (event_uuid, track_id, artist, event_type, value, created_at)
			 VALUES (?,?,?,?,?,?)`,
			"rf"+itoa(i), "recent"+itoa(i), "Recent"+itoa(i), "like", 5.0, time.Now().UTC().Format(time.RFC3339)); err != nil {
			t.Fatal(err)
		}
	}
	cutoff := time.Now().AddDate(0, 0, -21)
	if _, _, err := d.RecomputeTasteClusters("recent", &cutoff); err != nil {
		t.Fatal(err)
	}

	cands := []string{"cand_far", "cand_recent_genre"}
	got, reordered, err := d.OrderRadio("seed", cands)
	if err != nil {
		t.Fatal(err)
	}
	if !reordered {
		t.Fatal("expected reordered")
	}
	pos := map[string]int{}
	for i, id := range got {
		pos[id] = i
	}
	if pos["cand_recent_genre"] > pos["cand_far"] {
		t.Errorf("recent-layer affinity should lift cand_recent_genre above cand_far: pos=%v", pos)
	}
}
