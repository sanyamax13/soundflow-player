package main

import (
	"context"
	"testing"
)

// При равном (нулевом) очке по артисту звук решает порядок: кандидат, чей
// отпечаток ближе к центру вкуса, должен оказаться выше в списке «Волны»
// (Alex TG 24.09.2026: «не по артисту, не по песне, а по звучанию»).
func TestWaveRanksBySoundWhenArtistScoreTied(t *testing.T) {
	e := ctxFixture(t)
	if err := e.s.db.SetTasteClustersForTest("long_term", [][]float32{clipVec(10)}); err != nil {
		t.Fatal(err)
	}
	waveSidecar(t, []yandexWaveOut{
		{YandexID: "far", Artist: "Чужой1", Title: "Далёкая по звуку"},
		{YandexID: "near", Artist: "Чужой2", Title: "Близкая по звуку"},
	})
	var calls []string
	e.s.waveEmbed = func(_ context.Context, it yandexWaveOut) ([]float32, error) {
		calls = append(calls, it.YandexID)
		if it.YandexID == "near" {
			return clipVec(10), nil // тот же вектор, что центр — похожесть 1.0
		}
		return clipVec(-10), nil // противоположный — похожесть ~0
	}

	out, code, err := e.s.buildWave(context.Background())
	if err != nil || code != 0 {
		t.Fatalf("сбор: %d %v", code, err)
	}
	if len(out) != 2 {
		t.Fatalf("ждали 2 кандидата, получили %d: %+v", len(out), out)
	}
	if out[0].YandexID != "near" {
		t.Errorf("ближний по звуку должен быть первым, получили порядок: %s, %s", out[0].YandexID, out[1].YandexID)
	}
	if len(calls) != 2 {
		t.Errorf("оба кандидата должны были разбираться по звуку, разобрано: %v", calls)
	}

	// Второй сбор — из кэша (wave_vectors), не должен снова считать отпечатки заново.
	calls = nil
	if _, _, err := e.s.buildWave(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 0 {
		t.Errorf("второй сбор должен брать отпечатки из кэша: разборов %v", calls)
	}
}

// Нет центров вкуса (лайков ещё не набралось) — звук не трогаем вообще,
// «Волна» ранжируется как раньше, по артисту.
func TestWaveSkipsSoundWithoutClusters(t *testing.T) {
	e := ctxFixture(t)
	waveSidecar(t, []yandexWaveOut{{YandexID: "x", Artist: "Кто-то", Title: "Песня"}})
	calls := 0
	e.s.waveEmbed = func(context.Context, yandexWaveOut) ([]float32, error) { calls++; return clipVec(10), nil }

	if _, _, err := e.s.buildWave(context.Background()); err != nil {
		t.Fatal(err)
	}
	if calls != 0 {
		t.Errorf("без центров вкуса звук считать не должны, разборов: %d", calls)
	}
}

// Нет центров вкуса — автодокачка вообще не пытается (список отсортирован
// по артисту, это не «по звучанию»).
func TestAutoAcquireSkipsWithoutClusters(t *testing.T) {
	e := ctxFixture(t)
	items := []yandexWaveOut{{Artist: "A", Title: "B"}}
	e.s.autoAcquireFromWave(context.Background(), items) // не должно паниковать/зависать
}

// Центры есть, но качалка не готова (acquireService() == nil, т.к. sidecarURL
// пуст в тесте) — тоже тихо ничего не делает, не паникует.
func TestAutoAcquireNoopsWithoutSidecar(t *testing.T) {
	e := ctxFixture(t)
	if err := e.s.db.SetTasteClustersForTest("long_term", [][]float32{clipVec(10)}); err != nil {
		t.Fatal(err)
	}
	items := []yandexWaveOut{{Artist: "A", Title: "B"}}
	e.s.autoAcquireFromWave(context.Background(), items)
}
