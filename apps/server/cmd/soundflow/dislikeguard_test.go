package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/tasteguard"
)

// addVecSong — песня с отпечатком; alive — файл лежит на диске в «папке-сборнике» group.
func addVecSong(t *testing.T, e *ctxEnv, id, group string, vec []float32, alive bool) {
	t.Helper()
	local := filepath.Join(e.root, group, id+".mp3")
	if alive {
		if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(local, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	key := "art " + id + "__title " + id
	if err := e.s.db.InsertTrackWithFile(
		localdb.NewTrack{ID: id, Artist: "Art " + id, Title: "Title " + id, NormalizedKey: key},
		localdb.NewTrackFile{ID: "f_" + id, NormalizedKey: key, FilePath: local, SizeBytes: 1}); err != nil {
		t.Fatal(err)
	}
	if err := e.s.db.SetFeatureVector(id, vec); err != nil {
		t.Fatal(err)
	}
}

func vecAround(rng *rand.Rand, base, shift []float64, withShift bool) []float32 {
	v := make([]float32, localdb.VecDim)
	for i := range v {
		c := base[i]
		if withShift {
			c += shift[i]
		}
		v[i] = float32(c + rng.NormFloat64())
	}
	return v
}

// fillTaste — 150 «не нравится» (часть меткой «не качать», часть оценкой с телефона), 40 «нравится» (избранное)
// и 300 обычных песен; sep — насколько звук «не нравится» отличается от остального (0 — ничем).
func fillTaste(t *testing.T, e *ctxEnv, sep float64) {
	t.Helper()
	rng := rand.New(rand.NewSource(11))
	base := make([]float64, localdb.VecDim)
	shift := make([]float64, localdb.VecDim)
	for i := range base {
		base[i] = rng.NormFloat64()
		shift[i] = sep * rng.NormFloat64()
	}
	n := 0
	add := func(count int, prefix string, neg bool, setup func(id string)) {
		for i := 0; i < count; i++ {
			id := fmt.Sprintf("%s%d", prefix, i)
			addVecSong(t, e, id, fmt.Sprintf("Сборник %s%d", prefix, i/10), vecAround(rng, base, shift, neg), true)
			if setup != nil {
				setup(id)
			}
			n++
		}
	}
	add(100, "n", true, func(id string) { blockSong(t, e, id) })
	add(50, "m", true, func(id string) {
		if _, err := e.s.db.SQL().Exec(`INSERT INTO feedback_event (event_uuid, track_id, event_type, value, created_at)
			VALUES (?, ?, 'delete_not_my_taste', -5, '2026-09-20T00:00:00Z')`, "u-"+id, id); err != nil {
			t.Fatal(err)
		}
	})
	add(40, "p", false, func(id string) {
		if _, err := e.s.db.SQL().Exec(`INSERT INTO legacy_marks (normalized_key,kind,artist,title,marked_at)
			VALUES (?, 'favorite', '', '', '2026-09-20T00:00:00Z')`, "art "+id+"__title "+id); err != nil {
			t.Fatal(err)
		}
	})
	add(300, "k", false, nil)
	// удалённая Проводником песня без оценки в выборку не попадает
	addVecSong(t, e, "gone", "Удалённое", vecAround(rng, base, shift, false), false)
}

// Звук «не нравится» не отличает (как на живых данных 21.09.2026) — фильтр остаётся выключенным, модели нет,
// причина записана для окна «Вкус».
func TestGuardStaysOffWhenSoundDoesNotHelp(t *testing.T) {
	e := ctxFixture(t)
	fillTaste(t, e, 0)

	st, err := e.s.runDislikeGuard()
	if err != nil {
		t.Fatal(err)
	}
	if st.Enabled || st.Reason == "" || st.Neg != 150 || st.Pos != 40 || st.Kept != 300 {
		t.Fatalf("ждали «выключено» с причиной и выборкой 150/40/300 (без удалённой): %+v", st)
	}
	if _, ok := e.s.guardModel(); ok {
		t.Fatal("модель не должна быть сохранена")
	}
	rec := httptest.NewRecorder()
	e.s.hGuardStatus(rec, httptest.NewRequest("GET", "/api/taste/dislike-guard", nil))
	var got struct {
		State  *guardState `json:"state"`
		MinAUC float64     `json:"min_auc"`
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &got) != nil || got.State == nil || got.State.Enabled || got.MinAUC != 0.8 {
		t.Fatalf("статус: %d %s", rec.Code, rec.Body.String())
	}
}

// Звук начал отличать — программа сама включает фильтр и сохраняет модель.
func TestGuardEnablesWhenSoundHelps(t *testing.T) {
	e := ctxFixture(t)
	fillTaste(t, e, 0.15)

	st, err := e.s.runDislikeGuard()
	if err != nil {
		t.Fatal(err)
	}
	if !st.Enabled || st.AUCKept < tasteguard.MinAUC || st.AUCPos < tasteguard.MinAUC {
		t.Fatalf("ждали включение при высокой точности: %+v", st)
	}
	m, ok := e.s.guardModel()
	if !ok || len(m.W) != localdb.VecDim {
		t.Fatalf("модель должна быть сохранена: %v %d", ok, len(m.W))
	}
	// оценки ухудшились (данные стали шумом) — перепроверка выключает фильтр и стирает модель
	if _, err := e.s.db.SQL().Exec(`UPDATE tracks SET feature_vector = NULL`); err != nil {
		t.Fatal(err)
	}
	st, err = e.s.runDislikeGuard()
	if err != nil || st.Enabled {
		t.Fatalf("без отпечатков фильтр должен выключиться: %+v %v", st, err)
	}
	if _, ok := e.s.guardModel(); ok {
		t.Fatal("после выключения модели быть не должно")
	}
}

// enableHandMadeGuard — включённый сторож с простой моделью: «похоже на не нравится» = сильная нулевая координата.
func enableHandMadeGuard(t *testing.T, e *ctxEnv) {
	t.Helper()
	m := tasteguard.Model{Threshold: 0.5, Mean: make([]float32, localdb.VecDim), Std: make([]float32, localdb.VecDim), W: make([]float32, localdb.VecDim)}
	for i := range m.Std {
		m.Std[i] = 1
	}
	m.W[0] = 1
	buf, _ := json.Marshal(m)
	st, _ := json.Marshal(guardState{At: "2026-09-21T00:00:00Z", Enabled: true})
	_ = e.s.db.SetSetting(settingGuardModel, string(buf))
	_ = e.s.db.SetSetting(settingGuardState, string(st))
}

func clipVec(first float32) []float32 {
	v := make([]float32, localdb.VecDim)
	v[0] = first
	for i := 1; i < len(v); i++ {
		v[i] = 0.01
	}
	return v
}

// Сторож включён: кандидат, похожий по звуку на «не нравится», в список «Волны» не попадает; остальные остаются;
// отпечаток кандидата считается один раз (второй сбор берёт из кэша).
func TestWaveDropsSoundAlikeWhenGuardOn(t *testing.T) {
	e := ctxFixture(t)
	enableHandMadeGuard(t, e)
	waveSidecar(t, []yandexWaveOut{
		{YandexID: "bad", Artist: "Чужой", Title: "Похожий на нелюбимое"},
		{YandexID: "good", Artist: "Другой", Title: "Нормальная песня"},
	})
	calls := 0
	e.s.waveEmbed = func(_ context.Context, it yandexWaveOut) ([]float32, error) {
		calls++
		if it.YandexID == "bad" {
			return clipVec(10), nil // после нормировки нулевая координата ≈ 1 ≥ порога 0,5
		}
		return clipVec(0), nil
	}

	out, code, err := e.s.buildWave(context.Background())
	if err != nil || code != 0 {
		t.Fatalf("сбор: %d %v", code, err)
	}
	if len(out) != 1 || out[0].YandexID != "good" || calls != 2 {
		t.Fatalf("ждали только «good», 2 разбора: %+v, разборов %d", out, calls)
	}
	if _, _, err := e.s.buildWave(context.Background()); err != nil || calls != 2 {
		t.Errorf("второй сбор должен брать отпечатки из кэша: разборов %d, %v", calls, err)
	}
}

// Кандидата не удалось разобрать — он остаётся (лучше лишнее предложить, чем выбросить хорошее).
func TestWaveKeepsCandidateWhenSoundUnavailable(t *testing.T) {
	e := ctxFixture(t)
	enableHandMadeGuard(t, e)
	waveSidecar(t, []yandexWaveOut{{YandexID: "x", Artist: "Кто-то", Title: "Не скачалось"}})
	e.s.waveEmbed = func(context.Context, yandexWaveOut) ([]float32, error) {
		return nil, errors.New("Яндекс не отдал песню")
	}

	out, _, err := e.s.buildWave(context.Background())
	if err != nil || len(out) != 1 {
		t.Fatalf("кандидат должен остаться: %+v %v", out, err)
	}
}

// Фильтр выключен (по умолчанию) — отпечатки кандидатов не считаются вообще, «Волна» работает как раньше.
func TestWaveDoesNotTouchSoundWhenGuardOff(t *testing.T) {
	e := ctxFixture(t)
	waveSidecar(t, []yandexWaveOut{{YandexID: "x", Artist: "Кто-то", Title: "Песня"}})
	calls := 0
	e.s.waveEmbed = func(context.Context, yandexWaveOut) ([]float32, error) { calls++; return clipVec(10), nil }

	out, _, err := e.s.buildWave(context.Background())
	if err != nil || len(out) != 1 || calls != 0 {
		t.Fatalf("при выключенном сторожe звук не смотрим: %+v, разборов %d, %v", out, calls, err)
	}
}
