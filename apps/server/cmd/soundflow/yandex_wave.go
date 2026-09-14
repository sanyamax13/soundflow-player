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

// hYandexWave — GET /api/yandex/wave: до 100 кандидатов на сегодня.
func (s *Service) hYandexWave(w http.ResponseWriter, r *http.Request) {
	today := time.Now().UTC().Format("2006-01-02")
	if date, ok, _ := s.db.GetSetting(settingWaveDate); ok && date == today {
		if raw, ok2, _ := s.db.GetSetting(settingWaveBatch); ok2 && raw != "" {
			var cached []yandexWaveOut
			if json.Unmarshal([]byte(raw), &cached) == nil {
				writeJSON(w, cached)
				return
			}
		}
	}

	url := s.sidecarURL()
	if url == "" {
		http.Error(w, "качалка ещё запускается — попробуй через минуту", 503)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	raw, err := sidecar.New(url).YandexWaveCandidates(ctx)
	if err != nil {
		http.Error(w, err.Error(), 502)
		return
	}

	artScore, err := s.db.ArtistFeedbackScores()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}

	type scored struct {
		item  sidecar.YandexWaveItem
		score float64
	}
	var kept []scored
	for _, it := range raw {
		key := quality.NormalizedKey(it.Artist, it.Title)
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
