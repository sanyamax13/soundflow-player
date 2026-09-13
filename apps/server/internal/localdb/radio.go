package localdb

import (
	"sort"
	"strings"
	"time"
)

// «Умное радио» (TASTE-PLAN §7, этап 5). Кнопка «Радио по этой песне» на
// телефоне набивает очередь треками, похожими по звуку на текущий. Раньше —
// чистый косинус к seed (OrderBySimilarity). Теперь поверх:
//   + подъём треков ближе к центрам вкуса
//   − просадка исполнителей с отрицательной оценкой
//   − просадка недавно пропущенных
//   антипузырь: примерно каждый 8-й слот — трек далеко от вкуса
//   ≤ 2 трека одного исполнителя подряд
// Полный запрет — только блок-лист (дизлайк/удаление), он и так вне выборки.

const radioSkipDays = 14

// farPercentile — какая доля кандидатов (снизу по aff) считается «далёкой
// от вкуса» для антипузыря. Фиксированное число (было 0.4) не подходит:
// реальные эмбеддинги (PANNs CNN14) дают косинусы, сжатые в узкий верхний
// диапазон (проверено на soundflow-lab.db 13.09.2026 — 0% ниже 0.5), так
// что абсолютный порог 0.4 никогда не срабатывал. Процентиль самокалибруется
// под любую реальную шкалу и не протухает при смене модели отпечатков.
const farPercentile = 0.20

// farThreshold — порог aff, ниже которого кандидат идёт в антипузырь:
// нижние farPercentile от текущего набора кандидатов. Пусто → 0 (никого
// не выбрать, антипузырь молча выключен — как было раньше при пустых cs).
func farThreshold(cs []radioCand) float64 {
	if len(cs) == 0 {
		return 0
	}
	affs := make([]float64, len(cs))
	for i, c := range cs {
		affs[i] = c.aff
	}
	sort.Float64s(affs)
	idx := int(float64(len(affs)) * farPercentile)
	if idx >= len(affs) {
		idx = len(affs) - 1
	}
	return affs[idx]
}

type radioCand struct {
	id      string
	artist  string
	score   float64
	aff     float64
	simSeed float64
}

// OrderRadio — как OrderBySimilarity, но с учётом вкуса. Нет отпечатка у
// seed или центров вкуса — поведение полностью совпадает с OrderBySimilarity.
func (d *DB) OrderRadio(seedID string, candidateIDs []string) (ordered []string, reordered bool, err error) {
	seedVec, err := d.featureVector(seedID)
	if err != nil {
		return nil, false, err
	}
	centsLong, err := d.tasteCentroidsLayer("long_term")
	if err != nil {
		return nil, false, err
	}
	if len(seedVec) == 0 || len(centsLong) == 0 || len(candidateIDs) == 0 {
		return d.OrderBySimilarity(seedID, candidateIDs)
	}
	centsRecent, err := d.tasteCentroidsLayer("recent") // может быть пуст — affRecent тогда 0
	if err != nil {
		return nil, false, err
	}
	sessVecs, err := d.sessionVectors() // может быть nil — affSession тогда 0
	if err != nil {
		return nil, false, err
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

	cutoff := time.Now().AddDate(0, 0, -radioSkipDays).UTC().Format(time.RFC3339)
	recentSkip := map[string]bool{}
	if rows, e := d.sql.Query(`
		SELECT DISTINCT track_id FROM sync_events
		WHERE kind = 'skip' AND track_id <> '' AND applied_at >= ?`, cutoff); e == nil {
		for rows.Next() {
			var id string
			if rows.Scan(&id) == nil {
				recentSkip[id] = true
			}
		}
		rows.Close()
	}

	seen := map[string]bool{seedID: true}
	var cs []radioCand
	for _, id := range candidateIDs {
		if id == seedID || seen[id] {
			continue
		}
		var artist string
		var b []byte
		if e := d.sql.QueryRow(`SELECT artist, feature_vector FROM tracks WHERE id = ?`, id).Scan(&artist, &b); e != nil {
			continue
		}
		v := blobToVec(b)
		if len(v) == 0 {
			continue
		}
		seen[id] = true
		sim := cosine(seedVec, v)
		affLong := tasteAffinity(centsLong, v)
		affRecent := tasteAffinity(centsRecent, v)
		affSession := tasteAffinity(sessVecs, v)
		aff := 0.60*affLong + 0.25*affRecent + 0.15*affSession
		sc := sim + 0.15*aff
		if a := artScore[artist]; a < 0 {
			sc -= 0.5 * clamp01(-a/3) // растёт с «нелюбовью», насыщается на -3
			if a <= -4 {
				sc -= 0.6 // явный дизлайк/удаление артиста — ощутимо вниз
			}
		}
		if recentSkip[id] {
			sc -= 0.25
		}
		cs = append(cs, radioCand{id: id, artist: artist, score: sc, aff: aff, simSeed: sim})
	}
	if len(cs) == 0 {
		return d.OrderBySimilarity(seedID, candidateIDs)
	}

	sort.SliceStable(cs, func(i, j int) bool {
		if cs[i].score != cs[j].score {
			return cs[i].score > cs[j].score
		}
		return cs[i].id < cs[j].id
	})

	// антипузырь: отдельная очередь «далеко от вкуса», по близости к seed
	threshold := farThreshold(cs)
	var far []radioCand
	for _, c := range cs {
		if c.aff < threshold {
			far = append(far, c)
		}
	}
	sort.SliceStable(far, func(i, j int) bool { return far[i].simSeed > far[j].simSeed })
	// emitted — какие id уже попали в merged, ЛЮБЫМ путём (обычным ходом по
	// cs или инъекцией антипузыря). Раньше отмечался только путь инъекции,
	// из-за чего far-кандидат, до которого обычный ход cs добирался РАНЬШЕ
	// своего 8-го слота, потом инъецировался ПОВТОРНО — дубль занимал слот,
	// а последний (самый низкий по score) кандидат из cs терялся вовсе.
	emitted := map[string]bool{}

	// собираем список: каждый 8-й слот — из far (если есть и ещё не взят)
	merged := make([]radioCand, 0, len(cs))
	mi := 0
	for pos := 0; len(merged) < len(cs); pos++ {
		if (pos+1)%8 == 0 {
			var pick *radioCand
			for i := range far {
				if !emitted[far[i].id] {
					pick = &far[i]
					break
				}
			}
			if pick != nil {
				emitted[pick.id] = true
				merged = append(merged, *pick)
				continue
			}
		}
		for mi < len(cs) && emitted[cs[mi].id] {
			mi++
		}
		if mi >= len(cs) {
			break
		}
		emitted[cs[mi].id] = true
		merged = append(merged, cs[mi])
		mi++
	}

	// ≤ 2 трека одного исполнителя подряд
	reordered = true
	var lastArtist string
	run := 0
	for len(merged) > 0 {
		pick := 0
		if run >= 2 {
			for i, c := range merged {
				if !strings.EqualFold(c.artist, lastArtist) {
					pick = i
					break
				}
			}
		}
		c := merged[pick]
		ordered = append(ordered, c.id)
		merged = append(merged[:pick], merged[pick+1:]...)
		if strings.EqualFold(c.artist, lastArtist) {
			run++
		} else {
			lastArtist = c.artist
			run = 1
		}
	}

	// кандидаты без отпечатка — в хвост в исходном порядке
	for _, id := range candidateIDs {
		if !seen[id] {
			ordered = append(ordered, id)
			seen[id] = true
		}
	}
	return ordered, reordered, nil
}
