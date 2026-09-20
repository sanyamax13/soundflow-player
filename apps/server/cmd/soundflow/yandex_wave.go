// Alex TG 14.09.2026: шаг 2 — «Волна» без личной рекомендации Яндекса.
// Источники сырых кандидатов (сайдкар, providers/yandex.go
// wave_candidates): ещё треки у лайкнутых артистов, популярное в тех же
// жанрах, похожие артисты. Отбор и ранжирование — здесь, своим вкус-
// движком (сумма feedback_event по артисту — тот же сигнал, что уже
// используют лайки/дизлайки/скипы на телефоне), НЕ Яндекс. Автозагрузки в
// Яндекс-аккаунт нет (Alex TG: «не стоит этого делать») — обучение только
// через уже существующий feedback_event на телефоне.
//
// Раз в день: пересчитываем при первом запросе за сутки, дальше отдаём
// кэш из app_settings (сам сбор занимает ~20 секунд — куча запросов к
// Яндексу, незачем гонять при каждом открытии вкладки).
package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"time"

	"soundflow/server/internal/quality"
	"soundflow/server/internal/sidecar"
)

const (
	settingWaveDate  = "wave_date"  // "2026-09-14" — когда последний раз пересобирали
	settingWaveBatch = "wave_batch" // JSON []yandexWaveOut — что показали в этот день
	waveMaxShown     = 100
)

type yandexWaveOut struct {
	YandexID    string `json:"yandex_id"`
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	CoverURL    string `json:"cover_url"`
	DurationSec int    `json:"duration_sec"`
	Genre       string `json:"genre"`
	Source      string `json:"source"`
}

// topPositiveArtists — до n артистов с положительным счётом, по убыванию.
func topPositiveArtists(scores map[string]float64, n int) []string {
	type kv struct {
		name  string
		score float64
	}
	pos := make([]kv, 0, len(scores))
	for a, s := range scores {
		if s > 0 {
			pos = append(pos, kv{a, s})
		}
	}
	sort.Slice(pos, func(i, j int) bool { return pos[i].score > pos[j].score })
	if len(pos) > n {
		pos = pos[:n]
	}
	out := make([]string, len(pos))
	for i, p := range pos {
		out[i] = p.name
	}
	return out
}

// hYandexWave — GET /api/yandex/wave: до 100 кандидатов на сегодня. С ?refresh=1 («Пересобрать волну»,
// Alex TG 20208: «чтобы я сам мог каждый день её обновлять») список собирается заново, минуя кэш дня:
// скачанное и убранное из списка уходит, на его место встают следующие песни. Не вышло собрать (качалка
// молчит) — прежний список остаётся как был.
func (s *Service) hYandexWave(w http.ResponseWriter, r *http.Request) {
	today := time.Now().UTC().Format("2006-01-02")
	force := r.URL.Query().Get("refresh") == "1"
	if !force {
		if date, ok, _ := s.db.GetSetting(settingWaveDate); ok && date == today {
			if raw, ok2, _ := s.db.GetSetting(settingWaveBatch); ok2 && raw != "" {
				var cached []yandexWaveOut
				if json.Unmarshal([]byte(raw), &cached) == nil {
					writeJSON(w, dropLiveWave(s.dropDismissedWave(cached)))
					return
				}
			}
		}
	}
	if !s.waveMu.TryLock() {
		http.Error(w, "волна уже пересобирается — подожди минуту", http.StatusConflict)
		return
	}
	defer s.waveMu.Unlock()

	sidecarAddr := s.sidecarURL()
	if sidecarAddr == "" {
		http.Error(w, "качалка ещё запускается — попробуй через минуту", 503)
		return
	}

	artScore, err := s.db.ArtistFeedbackScores()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	// Артисты, залайканные на ТЕЛЕФОНЕ (не только Яндекс-лайки) — Alex TG
	// 15.09.2026. Отрицательный счёт (дизлайкнутый артист) сюда не годится —
	// это seed для РАСШИРЕНИЯ пула, а не для сужения.
	extraArtists := topPositiveArtists(artScore, 10)

	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	raw, err := sidecar.New(sidecarAddr).YandexWaveCandidates(ctx, extraArtists)
	if err != nil {
		http.Error(w, err.Error(), 502)
		return
	}

	type scored struct {
		item  sidecar.YandexWaveItem
		score float64
	}
	var kept []scored
	dismissed, _ := s.db.DismissedDiscover()
	for _, it := range raw {
		key := quality.NormalizedKey(it.Artist, it.Title)
		if dismissed[key] || isLiveWaveItem(it.Title, it.Album) {
			continue
		}
		if have, _ := s.db.TrackExistsByKey(key); have {
			continue
		}
		if blocked, _ := s.db.IsBlocked(key); blocked {
			continue
		}
		kept = append(kept, scored{item: it, score: artScore[it.Artist]})
	}
	// сначала то, что по артисту уже хорошо себя показало (лайки/недавние
	// прослушивания), внутри равного счёта — как пришло от сайдкара
	// (артист → жанр → похожие артисты, уже расставлено по важности).
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].score > kept[j].score })

	out := make([]yandexWaveOut, 0, waveMaxShown)
	for _, k := range kept {
		if len(out) >= waveMaxShown {
			break
		}
		out = append(out, yandexWaveOut{
			YandexID: k.item.YandexID, Artist: k.item.Artist, Title: k.item.Title,
			Album: k.item.Album, CoverURL: k.item.CoverURL, DurationSec: k.item.DurationSec,
			Genre: k.item.Genre, Source: k.item.Source,
		})
	}

	if buf, err := json.Marshal(out); err == nil {
		_ = s.db.SetSetting(settingWaveBatch, string(buf))
		_ = s.db.SetSetting(settingWaveDate, today)
	}
	writeJSON(w, out)
}
