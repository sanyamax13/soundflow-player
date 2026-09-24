package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"soundflow/server/internal/inference"
	"soundflow/server/internal/localdb"
	"soundflow/server/internal/tasteguard"
)

// «Сторож по звуку» для «Волны» (Alex TG 20239: «понять, что в этой песне такого особенного, чтобы таких больше не
// предлагало и не скачивало»; TG 20256/20259: по звуку, вариант 1 — проверять себя раз в неделю и включаться,
// только когда точность дойдёт до 80 %).
//
// 21.09.2026 проверка на данных Alex (cmd/soundflow-tasteeval) дала точность 0,55–0,66 — звук «не нравится» почти не
// отличает: метки «не нравится» — в основном песни из выброшенных сборников целиком. Поэтому фильтр по умолчанию
// ВЫКЛЮЧЕН. Раз в неделю программа заново обучается на всех оценках Alex, проверяет себя по папкам (internal/tasteguard)
// и, если точность ≥ tasteguard.MinAUC, сохраняет модель и включает отсев: кандидаты «Волны», похожие по звуку на «не
// нравится», в список не попадают (а значит и не качаются). Не дошла — модели нет, «Волна» работает как раньше, а в
// окне «Вкус» написано, почему не включено. Кандидата, которого не удалось разобрать, никогда не отсеиваем: лучше
// лишнее предложить, чем выбросить хорошее.

const (
	settingGuardState = "dislike_guard" // JSON guardState — итог последней проверки
	settingGuardModel = "dislike_model" // JSON tasteguard.Model — модель, пока фильтр включён

	guardEvery      = 7 * 24 * time.Hour // как часто перепроверять
	guardFirstDelay = 10 * time.Minute   // первая проверка после запуска (сначала пусть всё поднимется)
	guardCheckEvery = 6 * time.Hour      // как часто смотреть, не пора ли

	waveSoundPool   = 150             // сколько кандидатов разбираем по звуку, чтобы после отсева хватило на waveMaxShown
	waveSoundBudget = 4 * time.Minute // сколько времени даём на скачивание и разбор отрывков за один сбор списка
	waveVectorKeep  = 14 * 24 * time.Hour
	// Кусок трека для отпечатка кандидата (не вся песня — быстрее и меньше
	// «размывается» усреднением по вступлению/тишине). Отпечаток
	// детерминирован для одной и той же модели/окна — можно было бы хранить
	// вечно, TTL выше стоит по другой причине (сама песня в «Волне» не
	// живёт дольше пары недель, а не потому что отпечаток «устарел»).
	waveEmbedWindowSec = 20
	waveClipMax        = 25 << 20 // песня больше 25 МБ — не наша (защита от мусора вместо mp3)
)

// guardState — итог последней проверки (то, что показывает окно «Вкус»). -1 в точности — «не считалась».
type guardState struct {
	At        string  `json:"at"`
	Neg       int     `json:"neg"`
	Pos       int     `json:"pos"`
	Kept      int     `json:"kept"`
	Lambda    float64 `json:"lambda"`
	AUCPos    float64 `json:"auc_pos"`
	AUCKept   float64 `json:"auc_kept"`
	Catch     float64 `json:"catch"`
	Threshold float64 `json:"threshold"`
	Enabled   bool    `json:"enabled"`
	Reason    string  `json:"reason"`
}

func nanTo(v, def float64) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return def
	}
	return v
}

func (s *Service) loadGuardState() (guardState, bool) {
	raw, ok, err := s.db.GetSetting(settingGuardState)
	if err != nil || !ok || raw == "" {
		return guardState{}, false
	}
	var st guardState
	if json.Unmarshal([]byte(raw), &st) != nil {
		return guardState{}, false
	}
	return st, true
}

// guardModel — модель сторожа, если фильтр сейчас включён.
func (s *Service) guardModel() (tasteguard.Model, bool) {
	st, ok := s.loadGuardState()
	if !ok || !st.Enabled {
		return tasteguard.Model{}, false
	}
	raw, ok, err := s.db.GetSetting(settingGuardModel)
	if err != nil || !ok || raw == "" {
		return tasteguard.Model{}, false
	}
	var m tasteguard.Model
	if json.Unmarshal([]byte(raw), &m) != nil || len(m.W) == 0 {
		return tasteguard.Model{}, false
	}
	return m, true
}

// dislikeSamples — обучающая выборка: песни с отпечатком и их оценка. «Не нравится» — метка «не качать» или сумма
// оценок с телефона < 0; «нравится» — избранное или сумма > 0; остальные — обычные песни библиотеки, но только те, чей
// файл правда лежит на диске (удалённые Проводником без оценки — не «обычные», а неизвестно что). Группа песни —
// её папка: проверка не даёт песням одного сборника подсказывать друг другу.
func (s *Service) dislikeSamples() ([]tasteguard.Sample, error) {
	var out []tasteguard.Sample
	err := s.db.ForEachTrainingRow(func(r localdb.TrainingRow) bool {
		if len(r.Vec) != localdb.VecDim {
			return true
		}
		neg := r.Mark == "blocked" || r.Feedback < 0
		pos := r.Mark == "favorite" || r.Feedback > 0
		if neg && pos {
			return true // противоречие — в выборку не берём
		}
		group, alive := r.TrackID, false
		if r.Path != "" {
			local := s.localPath(r.Path)
			group = strings.ToLower(filepath.Dir(local))
			if fi, err := os.Stat(local); err == nil && !fi.IsDir() {
				alive = true
			}
		}
		if !neg && !pos && !alive {
			return true
		}
		out = append(out, tasteguard.Sample{Vec: r.Vec, Group: group, Neg: neg, Pos: pos})
		return true
	})
	return out, err
}

// runDislikeGuard — обучиться на текущих оценках, проверить себя и решить, включать ли фильтр. Одновременно — один запуск.
func (s *Service) runDislikeGuard() (guardState, error) {
	s.guardMu.Lock()
	defer s.guardMu.Unlock()

	samples, err := s.dislikeSamples()
	if err != nil {
		return guardState{}, fmt.Errorf("не прочитала оценки: %w", err)
	}
	rep, _, err := tasteguard.Evaluate(samples)
	if err != nil {
		return guardState{}, fmt.Errorf("проверка не вышла: %w", err)
	}
	st := guardState{
		At: time.Now().UTC().Format(time.RFC3339), Neg: rep.Neg, Pos: rep.Pos, Kept: rep.Kept,
		Lambda: rep.Lambda, AUCPos: nanTo(rep.AUCPos, -1), AUCKept: nanTo(rep.AUCKept, -1),
		Catch: rep.Catch, Threshold: nanTo(rep.Threshold, 0), Enabled: rep.Enabled, Reason: rep.Reason,
	}
	if rep.Enabled {
		model, terr := tasteguard.Train(samples, rep.Lambda)
		if terr != nil {
			st.Enabled, st.Reason = false, "модель не обучилась: "+terr.Error()
		} else {
			model.Threshold = rep.Threshold
			if buf, merr := json.Marshal(model); merr == nil {
				_ = s.db.SetSetting(settingGuardModel, string(buf))
			} else {
				st.Enabled, st.Reason = false, "модель не сохранилась: "+merr.Error()
			}
		}
	}
	if !st.Enabled {
		_ = s.db.SetSetting(settingGuardModel, "")
	}
	if buf, err := json.Marshal(st); err == nil {
		_ = s.db.SetSetting(settingGuardState, string(buf))
	}
	verdict := "выключен: " + st.Reason
	if st.Enabled {
		verdict = fmt.Sprintf("ВКЛЮЧЁН (отсеивает около %.0f %% «не нравится»)", 100*st.Catch)
	}
	_ = s.db.AddServerLog("info", "", "", fmt.Sprintf(
		"сторож по звуку: проверка на %d «не нравится», %d «нравится», %d обычных; точность %s; фильтр «Волны» %s",
		st.Neg, st.Pos, st.Kept, guardAUCText(st), verdict), 0)
	return st, nil
}

func guardAUCText(st guardState) string {
	worst := math.Inf(1)
	for _, a := range []float64{st.AUCPos, st.AUCKept} {
		if a >= 0 && a < worst {
			worst = a
		}
	}
	if math.IsInf(worst, 1) {
		return "не считалась"
	}
	return fmt.Sprintf("%.0f %%", 100*worst)
}

// dislikeGuardLoop — раз в неделю (проверяем каждые guardCheckEvery, не пора ли) перепроверяет точность.
func (s *Service) dislikeGuardLoop(ctx context.Context) {
	first := time.After(guardFirstDelay)
	tick := time.NewTicker(guardCheckEvery)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-first:
		case <-tick.C:
		}
		if st, ok := s.loadGuardState(); ok {
			if at, err := time.Parse(time.RFC3339, st.At); err == nil && time.Since(at) < guardEvery {
				continue
			}
		}
		if _, err := s.runDislikeGuard(); err != nil {
			_ = s.db.AddServerLog("error", "", "", "сторож по звуку: "+err.Error(), 0)
		}
	}
}

// GET /api/taste/dislike-guard — что показывает окно «Вкус»: итог последней проверки и пороги.
func (s *Service) hGuardStatus(w http.ResponseWriter, r *http.Request) {
	var state any
	if st, ok := s.loadGuardState(); ok {
		state = st
	}
	writeJSON(w, map[string]any{
		"state": state, "min_auc": tasteguard.MinAUC, "min_neg": tasteguard.MinNeg, "min_ref": tasteguard.MinRef,
		"min_catch": tasteguard.MinCatch, "false_reject": tasteguard.FalseReject,
	})
}

// POST /api/taste/dislike-guard/check — проверить сейчас, не дожидаясь недели (кнопка «Пересобрать» в «Вкусе»).
func (s *Service) hGuardCheck(w http.ResponseWriter, r *http.Request) {
	st, err := s.runDislikeGuard()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, st)
}

// dropBySound — если сторож включён, убрать из списка кандидатов, что по звуку похожи на «не нравится». Отпечаток
// кандидата берётся из кэша или считается по отрывку из Яндекса (не дольше waveSoundBudget на весь список); не удалось
// разобрать — кандидат остаётся.
func (s *Service) dropBySound(ctx context.Context, items []yandexWaveOut, model tasteguard.Model) []yandexWaveOut {
	embed := s.waveEmbed
	if embed == nil {
		if s.eng == nil {
			return items
		}
		embed = s.embedCandidate
	}
	ctx, cancel := context.WithTimeout(ctx, waveSoundBudget)
	defer cancel()
	_ = s.db.PruneWaveVectors(time.Now().Add(-waveVectorKeep))

	out := make([]yandexWaveOut, 0, len(items))
	dropped, unknown := 0, 0
	for _, it := range items {
		if it.YandexID == "" || ctx.Err() != nil {
			out = append(out, it)
			unknown++
			continue
		}
		vec, ok, _ := s.db.WaveVector(it.YandexID)
		if !ok {
			v, err := embed(ctx, it)
			if err != nil || len(v) == 0 {
				out = append(out, it)
				unknown++
				continue
			}
			vec = v
			_ = s.db.SetWaveVector(it.YandexID, vec)
		}
		if model.Reject(vec) {
			dropped++
			continue
		}
		out = append(out, it)
	}
	_ = s.db.AddServerLog("info", "", "", fmt.Sprintf(
		"волна: по звуку отсеяно %d из %d (не разобрано %d)", dropped, len(items), unknown), 0)
	return out
}

// embedCandidate — отпечаток кандидата: песня из Яндекса (та же ссылка, что у прослушивания в окне) → PCM → CNN14.
func (s *Service) embedCandidate(ctx context.Context, it yandexWaveOut) ([]float32, error) {
	if s.eng == nil {
		return nil, errors.New("нет модели отпечатков")
	}
	u, err := s.previewURL(ctx, it.YandexID, it.Artist, it.Title, false)
	if err != nil {
		return nil, err
	}
	cctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := previewHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("Яндекс не отдал песню: %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, waveClipMax+1))
	if err != nil {
		return nil, err
	}
	if len(data) > waveClipMax {
		return nil, errors.New("файл слишком большой")
	}
	pcm, err := inference.DecodePCMBytes(data)
	if err != nil {
		return nil, err
	}
	// Середина трека ~waveEmbedWindowSec секунд — не начало (тишина/вступление
	// смазывают отпечаток, ChatGPT/Gemini сошлись на этом же совете 24.09.2026).
	return s.eng.Embed(inference.MiddleWindow(pcm, waveEmbedWindowSec))
}
