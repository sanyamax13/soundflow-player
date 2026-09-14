package localdb

import (
	"math"
	"math/rand"
	"sort"
	"time"
)

// Автоподбор «что скачать» (TASTE-PLAN §4-6, этап 4). Кандидаты — треки
// каталога, которых нет на телефоне и которые не в блок-листе. Раскладываем
// по каналам с квотами, ранжируем, разнообразим (MMR). Локальные каналы
// (по вкусу / забытое / разведка / случайное) — здесь; «новые релизы
// любимых артистов» и «похожие артисты (Яндекс)» подключим, когда будет
// внешний источник. Не качаем молча — список идёт в окно с галочками.

// Квоты каналов на 100 (§4, минус два внешних — их доля перераспределена).
const (
	quotaTaste       = 45 // похожие на вкус по звуку
	quotaForgotten   = 20 // в каталоге, когда-то нравилось, давно не играл
	quotaExploration = 20 // рядом с кластером, но не в центре
	quotaRandom      = 15 // случайное
)

// forgottenDays — «давно не играл» для канала «забытое».
const forgottenDays = 30

// Suggestion — предложение к скачиванию.
type Suggestion struct {
	ID     string  `json:"id"`
	Artist string  `json:"artist"`
	Title  string  `json:"title"`
	Score  float64 `json:"score"`
	Reason string  `json:"reason"` // «по вкусу» | «забытое» | «на пробу» | «случайное»
}

type suggCand struct {
	id     string
	artist string
	title  string
	vec    []float32 // L2-нормированный
	aff    float64   // близость к вкусу (0..1), 0 если центров нет
	artScr float64   // оценка исполнителя из feedback_event
	stale  bool      // не играл давно (или никогда) — для «забытого»
}

// SuggestDownloads — n предложений «что скачать» для устройства. Пусто, если
// каталог кончился.
func (d *DB) SuggestDownloads(deviceID string, n int) ([]Suggestion, error) {
	if n <= 0 {
		n = 30
	}
	have, err := d.DeviceTrackIDs(deviceID)
	if err != nil {
		return nil, err
	}

	artScore := map[string]float64{}
	if rows, e := d.sql.Query(`SELECT artist, SUM(value) FROM feedback_event WHERE artist <> '' GROUP BY artist`); e == nil {
		for rows.Next() {
			var a string
			var s float64
			if rows.Scan(&a, &s) == nil {
				artScore[a] = s
			}
		}
		rows.Close()
	}

	cutoff := time.Now().AddDate(0, 0, -forgottenDays).UTC().Format(time.RFC3339)
	recentPlay := map[string]bool{} // играл за последние forgottenDays
	if rows, e := d.sql.Query(`
		SELECT DISTINCT track_id FROM sync_events
		WHERE kind = 'play' AND track_id <> '' AND applied_at >= ?`, cutoff); e == nil {
		for rows.Next() {
			var id string
			if rows.Scan(&id) == nil {
				recentPlay[id] = true
			}
		}
		rows.Close()
	}

	cents, err := d.tasteCentroidsLayer("long_term")
	if err != nil {
		return nil, err
	}

	rows, err := d.sql.Query(catalogSelect + ` AND tf.id IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var cands []suggCand
	for rows.Next() {
		var t CatalogTrack
		if err := rows.Scan(&t.ID, &t.Artist, &t.Title, &t.Album, &t.DurationSec,
			&t.ReleaseKind, &t.Explicit, &t.CoverURL, &t.Favorite,
			&t.SizeBytes, &t.BitrateKbps, &t.MimeType, &t.HasFP); err != nil {
			return nil, err
		}
		if have[t.ID] {
			continue
		}
		var b []byte
		if e := d.sql.QueryRow(`SELECT feature_vector FROM tracks WHERE id = ?`, t.ID).Scan(&b); e != nil {
			continue
		}
		v := blobToVec(b)
		if len(v) == 0 {
			continue
		}
		cands = append(cands, suggCand{
			id: t.ID, artist: t.Artist, title: t.Title, vec: l2norm(v),
			aff:    tasteAffinity(cents, v),
			artScr: artScore[t.Artist],
			stale:  !recentPlay[t.ID],
		})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(cands) == 0 {
		return []Suggestion{}, nil
	}

	// перемешиваем — устойчивый сид, но не по алфавиту/дате внутри равных
	rng := rand.New(rand.NewSource(1))
	rng.Shuffle(len(cands), func(i, j int) { cands[i], cands[j] = cands[j], cands[i] })

	pref := func(c suggCand) float64 { return c.aff + 0.25*clamp01(c.artScr/10) }

	byTaste := append([]suggCand(nil), cands...)
	sort.SliceStable(byTaste, func(i, j int) bool { return pref(byTaste[i]) > pref(byTaste[j]) })

	forgotten := make([]suggCand, 0)
	for _, c := range cands {
		if c.artScr > 0 && c.stale {
			forgotten = append(forgotten, c)
		}
	}
	sort.SliceStable(forgotten, func(i, j int) bool { return forgotten[i].artScr > forgotten[j].artScr })

	explore := make([]suggCand, 0)
	for _, c := range cands {
		if c.aff >= 0.45 && c.aff <= 0.78 {
			explore = append(explore, c)
		}
	}
	sort.SliceStable(explore, func(i, j int) bool { return explore[i].aff > explore[j].aff })

	take := func(src []suggCand, k int, reason string, used map[string]bool, out *[]Suggestion) {
		for _, c := range src {
			if k <= 0 {
				return
			}
			if used[c.id] {
				continue
			}
			used[c.id] = true
			*out = append(*out, Suggestion{ID: c.id, Artist: c.artist, Title: c.title,
				Score: round2(pref(c)), Reason: reason})
			k--
		}
	}

	used := map[string]bool{}
	var picks []Suggestion
	take(byTaste, n*quotaTaste/100+1, "по вкусу", used, &picks)
	take(forgotten, n*quotaForgotten/100+1, "забытое", used, &picks)
	take(explore, n*quotaExploration/100+1, "на пробу", used, &picks)
	take(cands, n*quotaRandom/100+1, "случайное", used, &picks) // cands уже перемешаны
	take(byTaste, n, "по вкусу", used, &picks)                  // добор

	// MMR-разнообразие: следующий = argmax(pref − λ·макс. похожесть на уже выбранное)
	vecByID := make(map[string][]float32, len(cands))
	for _, c := range cands {
		vecByID[c.id] = c.vec
	}
	const lambda = 0.35
	ordered := make([]Suggestion, 0, n)
	for len(picks) > 0 && len(ordered) < n {
		bi, best := 0, math.Inf(-1)
		for i, p := range picks {
			sim := 0.0
			for _, o := range ordered {
				if s := dotF32(vecByID[p.ID], vecByID[o.ID]); s > sim {
					sim = s
				}
			}
			if m := p.Score - lambda*sim; m > best {
				best, bi = m, i
			}
		}
		ordered = append(ordered, picks[bi])
		picks = append(picks[:bi], picks[bi+1:]...)
	}
	return ordered, nil
}

func clamp01(x float64) float64 {
	if x < 0 {
		return 0
	}
	if x > 1 {
		return 1
	}
	return x
}

func round2(x float64) float64 { return math.Round(x*100) / 100 }
