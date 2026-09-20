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
//
// 21.09.2026 (Alex TG 20212/20214): «список раз в день + история предыдущих 3 дней». День считаем по
// времени компьютера (раньше по UTC — у Alex UTC+8, и список менялся в 8 утра); программа сама собирает
// подборку с утра (waveDailyLoop), не дожидаясь, пока Alex откроет вкладку, — иначе история была бы
// дырявой. Прошлые дни лежат в wave_history; у каждого дня своя дата, дни без списка просто пропускаются.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"time"

	"soundflow/server/internal/quality"
	"soundflow/server/internal/sidecar"
)

const (
	settingWaveDate    = "wave_date"    // "2026-09-14" — день (по времени компьютера), за который собран сегодняшний список
	settingWaveBatch   = "wave_batch"   // JSON []yandexWaveOut — список за день wave_date
	settingWaveHistory = "wave_history" // JSON []waveDay — прошлые дни (не старше waveHistoryDays), новые впереди
	waveMaxShown       = 100
	waveHistoryDays    = 3 // сегодня + 3 прошлых дня
	waveAutoHour       = 6 // с этого часа (по компьютеру) программа сама собирает подборку на сегодня
)

// waveDay — список «Волны» за один день.
type waveDay struct {
	Date  string          `json:"date"`
	Items []yandexWaveOut `json:"items"`
}

// waveDayInfo — строка ответа /api/yandex/wave/days: за какой день есть список.
type waveDayInfo struct {
	Day   int    `json:"day"` // 0 — сегодня, 1 — вчера, …
	Date  string `json:"date"`
	Label string `json:"label"`
	Count int    `json:"count"` // сколько песен из списка ещё можно скачать
}

// waveDate — день по времени компьютера.
func waveDate(t time.Time) string { return t.Format("2006-01-02") }

// waveDayLabel — как назвать день в окне: 0 — «Сегодня», 1 — «Вчера», дальше «N дня назад».
func waveDayLabel(n int) string {
	switch n {
	case 0:
		return "Сегодня"
	case 1:
		return "Вчера"
	}
	return fmt.Sprintf("%d дня назад", n)
}

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

// filterWave — то, что не надо предлагать: убранное Alex из списка, живые записи, песни, что уже в каталоге
// или помечены «больше не качать». Применяется при каждом показе (в том числе к прошлым дням): за день
// часть песен могла попасть в каталог.
func (s *Service) filterWave(items []yandexWaveOut) []yandexWaveOut {
	out := dropLiveWave(s.dropKnownWave(s.dropDismissedWave(items)))
	if out == nil {
		out = []yandexWaveOut{}
	}
	return out
}

// loadWaveDays — все сохранённые списки по датам: прошлые дни из истории и список за wave_date (он может
// быть вчерашним, пока сегодняшний ещё не собран).
func (s *Service) loadWaveDays() map[string][]yandexWaveOut {
	days := map[string][]yandexWaveOut{}
	if raw, ok, _ := s.db.GetSetting(settingWaveHistory); ok && raw != "" {
		var hist []waveDay
		if json.Unmarshal([]byte(raw), &hist) == nil {
			for _, d := range hist {
				days[d.Date] = d.Items
			}
		}
	}
	if date, ok, _ := s.db.GetSetting(settingWaveDate); ok && date != "" {
		if raw, ok2, _ := s.db.GetSetting(settingWaveBatch); ok2 && raw != "" {
			var batch []yandexWaveOut
			if json.Unmarshal([]byte(raw), &batch) == nil {
				days[date] = batch
			}
		}
	}
	return days
}

// saveWave — записать список за день today; списки прошлых дней (не старше waveHistoryDays) уходят в историю,
// более старые пропадают.
func (s *Service) saveWave(today string, out []yandexWaveOut) {
	days := s.loadWaveDays()
	delete(days, today)
	hist := []waveDay{}
	if day0, err := time.ParseInLocation("2006-01-02", today, time.Local); err == nil {
		oldest := waveDate(day0.AddDate(0, 0, -waveHistoryDays))
		for date, items := range days {
			if date >= oldest && date < today && len(items) > 0 {
				hist = append(hist, waveDay{Date: date, Items: items})
			}
		}
		sort.Slice(hist, func(i, j int) bool { return hist[i].Date > hist[j].Date })
	}
	if buf, err := json.Marshal(hist); err == nil {
		_ = s.db.SetSetting(settingWaveHistory, string(buf))
	}
	if buf, err := json.Marshal(out); err == nil {
		_ = s.db.SetSetting(settingWaveBatch, string(buf))
		_ = s.db.SetSetting(settingWaveDate, today)
	}
}

// buildWave — собрать список «Волны» у качалки (до 100 песен). code — какой HTTP-код отдать окну, если не вышло.
func (s *Service) buildWave(ctx context.Context) (out []yandexWaveOut, code int, err error) {
	sidecarAddr := s.sidecarURL()
	if sidecarAddr == "" {
		return nil, http.StatusServiceUnavailable, errors.New("качалка ещё запускается — попробуй через минуту")
	}

	artScore, err := s.db.ArtistFeedbackScores()
	if err != nil {
		return nil, http.StatusInternalServerError, err
	}
	// Артисты, залайканные на ТЕЛЕФОНЕ (не только Яндекс-лайки) — Alex TG
	// 15.09.2026. Отрицательный счёт (дизлайкнутый артист) сюда не годится —
	// это seed для РАСШИРЕНИЯ пула, а не для сужения.
	extraArtists := topPositiveArtists(artScore, 10)

	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	raw, err := sidecar.New(sidecarAddr).YandexWaveCandidates(ctx, extraArtists)
	if err != nil {
		return nil, http.StatusBadGateway, err
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

	out = make([]yandexWaveOut, 0, waveMaxShown)
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
	return out, 0, nil
}

// hYandexWave — GET /api/yandex/wave: до 100 кандидатов на сегодня. С ?refresh=1 («Пересобрать волну»,
// Alex TG 20208: «чтобы я сам мог каждый день её обновлять») список собирается заново, минуя кэш дня:
// скачанное и убранное из списка уходит, на его место встают следующие песни. Не вышло собрать (качалка
// молчит) — прежний список остаётся как был. С ?day=1..3 — список за прошлый день (Alex TG 20212/20214:
// «история предыдущих 3 дней»): только то, что сохранено, ничего не пересобирается.
func (s *Service) hYandexWave(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	today := waveDate(now)
	if d := r.URL.Query().Get("day"); d != "" {
		n, err := strconv.Atoi(d)
		if err != nil || n < 0 || n > waveHistoryDays {
			http.Error(w, "день — от 0 (сегодня) до "+strconv.Itoa(waveHistoryDays), http.StatusBadRequest)
			return
		}
		if n > 0 {
			writeJSON(w, s.filterWave(s.loadWaveDays()[waveDate(now.AddDate(0, 0, -n))]))
			return
		}
	}
	force := r.URL.Query().Get("refresh") == "1"
	if !force {
		if date, ok, _ := s.db.GetSetting(settingWaveDate); ok && date == today {
			if raw, ok2, _ := s.db.GetSetting(settingWaveBatch); ok2 && raw != "" {
				var cached []yandexWaveOut
				if json.Unmarshal([]byte(raw), &cached) == nil {
					writeJSON(w, s.filterWave(cached))
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

	out, code, err := s.buildWave(r.Context())
	if err != nil {
		http.Error(w, err.Error(), code)
		return
	}
	s.saveWave(today, out)
	writeJSON(w, out)
}

// hYandexWaveDays — GET /api/yandex/wave/days: за какие дни есть списки. Сегодня — всегда; прошлые дни (до
// трёх) — если по ним что-то сохранено. Count — сколько песен из списка ещё можно скачать.
func (s *Service) hYandexWaveDays(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	days := s.loadWaveDays()
	out := []waveDayInfo{}
	for n := 0; n <= waveHistoryDays; n++ {
		date := waveDate(now.AddDate(0, 0, -n))
		items := days[date]
		if n > 0 && len(items) == 0 {
			continue
		}
		out = append(out, waveDayInfo{Day: n, Date: date, Label: waveDayLabel(n), Count: len(s.filterWave(items))})
	}
	writeJSON(w, out)
}

// waveDailyLoop — сама собирает подборку на сегодня, не дожидаясь, пока Alex откроет вкладку (Alex TG 20212:
// «список раз в день»; без этого история за 3 дня была бы дырявой). Первый заход через 5 минут после старта
// (качалке нужно время), дальше каждые 20 минут: пора ли (с waveAutoHour), нет ли уже списка за сегодня.
func (s *Service) waveDailyLoop(ctx context.Context) {
	first := time.After(5 * time.Minute)
	tick := time.NewTicker(20 * time.Minute)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-first:
		case <-tick.C:
		}
		s.waveDailyOnce(ctx, time.Now())
	}
}

// waveDailyOnce — один заход: собрать список на сегодня, если пора и его ещё нет. Качалка молчит — тихо ждём
// следующего круга.
func (s *Service) waveDailyOnce(ctx context.Context, now time.Time) {
	today := waveDate(now)
	built := func() bool {
		date, ok, _ := s.db.GetSetting(settingWaveDate)
		return ok && date == today
	}
	if now.Hour() < waveAutoHour || built() {
		return
	}
	if !s.waveMu.TryLock() {
		return // окно как раз собирает само
	}
	defer s.waveMu.Unlock()
	if built() {
		return
	}
	out, _, err := s.buildWave(ctx)
	if err != nil {
		return
	}
	s.saveWave(today, out)
	_ = s.db.AddServerLog("info", "", "", fmt.Sprintf("волна на сегодня собрана сама: %d песен", len(out)), 0)
}
