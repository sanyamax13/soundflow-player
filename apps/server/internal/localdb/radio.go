package localdb

import (
	"database/sql"
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
//   исполнитель — не раньше, чем через 3 других (было ≤ 2 подряд)
// Полный запрет — только блок-лист (дизлайк/удаление), он и так вне выборки.

const radioSkipDays = 14

// duplicateSimThreshold — косинус к seed от такого и выше считаем «тот же
// трек под другим id» (перевыпуск/другие кредиты артиста), не «похожее».
// Калибровано на РЕАЛЬНОМ каталоге 14.09.2026 (Alex TG, скрин: «Quintino —
// Party Never Ends» сыграл сразу второй раз как «ALOK, QUINTINO — Party
// Never Ends») — эта пара оказалась НЕ бит-в-бит (0.9962, разный мастеринг/
// перевыпуск), а реально похожие-но-разные треки в том же каталоге не
// поднимались выше ~0.91 (проверено прямым запросом /v1/stream/order:
// топ-непохожие CROATIA SQUAD — Pop Your Pussy 0.910, CALIPPO — 10 Words
// 0.898). 0.98 — с запасом посередине: выше реального разброса «похоже, но
// не то же самое», ниже реального дубликата.
const duplicateSimThreshold = 0.98

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

type trackVec struct {
	artist string
	vec    []float32
}

// fetchTracksByID — артист + звуковой отпечаток для набора id ОДНИМ (или
// несколькими, чанками) запросом вместо одного SELECT на каждый id по
// отдельности. Id без отпечатка (пустой feature_vector) или вовсе не
// найденные в таблице — просто отсутствуют в результате, вызывающий код и
// раньше трактовал такое как «нет отпечатка» (continue). Чанки по 400 —
// с запасом внутри лимита SQLite на число плейсхолдеров в одном запросе.
func fetchTracksByID(db *sql.DB, ids []string) map[string]trackVec {
	out := make(map[string]trackVec, len(ids))
	const chunkSize = 400
	for i := 0; i < len(ids); i += chunkSize {
		end := i + chunkSize
		if end > len(ids) {
			end = len(ids)
		}
		chunk := ids[i:end]
		placeholders := strings.TrimSuffix(strings.Repeat("?,", len(chunk)), ",")
		args := make([]any, len(chunk))
		for j, id := range chunk {
			args[j] = id
		}
		rows, e := db.Query(`SELECT id, artist, feature_vector FROM tracks WHERE id IN (`+placeholders+`)`, args...)
		if e != nil {
			continue
		}
		for rows.Next() {
			var id, artist string
			var b []byte
			if rows.Scan(&id, &artist, &b) != nil {
				continue
			}
			v := blobToVec(b)
			if len(v) == 0 {
				continue
			}
			out[id] = trackVec{artist: artist, vec: v}
		}
		rows.Close()
	}
	return out
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
	// Раньше был SELECT ПО ОДНОМУ id за раз — на живой библиотеке в тысячи
	// скачанных треков это тысячи последовательных запросов к SQLite, и
	// именно это (не сборка очереди на телефоне, та уже почищена) держало
	// кнопку «радио» ~10 секунд (Alex TG 14.09.2026: «нажимаю между секунд
	// 10, чтобы подобрало»). Один запрос с IN(...) вместо N — та же выборка,
	// на порядки быстрее. Чанками по 400 id — с запасом внутри лимита
	// SQLite на число плейсхолдеров в одном запросе.
	tracksByID := fetchTracksByID(d.sql, candidateIDs)
	var cs []radioCand
	for _, id := range candidateIDs {
		if id == seedID || seen[id] {
			continue
		}
		tr, ok := tracksByID[id]
		if !ok {
			continue
		}
		v := tr.vec
		artist := tr.artist
		sim := cosine(seedVec, v)
		// Тот же трек под другим id/названием (перевыпуск, другая версия
		// артиста в кредитах — «Quintino» vs «ALOK, QUINTINO», Alex TG
		// 14.09.2026: «одна и та же песня попала в очередь как похожая»,
		// проверено — 20 таких пар/троек в каталоге с БИТ-В-БИТ одинаковым
		// отпечатком). Косинус к себе самому — ~1.0, отличить от реально
		// близких по звуку РАЗНЫХ песен (те редко превышают ~0.9) можно
		// высоким порогом. Не убираем из очереди совсем — просто не
		// выдаём как «похожее» (ниже уйдёт в хвост без отпечатка).
		if sim >= duplicateSimThreshold {
			continue
		}
		seen[id] = true
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

	// Исполнитель — не раньше, чем через 3 других (26.09.2026, общий вывод пяти разборов; было «≤ 2
	// подряд»). Остались только те же исполнители — правило мягко ослабляется, песни не теряются.
	// То же правило на телефоне: apps/mobile/lib/core/local_taste.dart (_limitConsecutiveArtist).
	reordered = true
	const artistGap = 3
	artistOf := map[string]string{}
	for len(merged) > 0 {
		pick := 0
		for gap := artistGap; gap > 0; gap-- {
			found := -1
			for i, c := range merged {
				clash := false
				for j := len(ordered) - 1; j >= 0 && j >= len(ordered)-gap; j-- {
					if strings.EqualFold(artistOf[ordered[j]], c.artist) {
						clash = true
						break
					}
				}
				if !clash {
					found = i
					break
				}
			}
			if found >= 0 {
				pick = found
				break
			}
		}
		c := merged[pick]
		ordered = append(ordered, c.id)
		artistOf[c.id] = c.artist
		merged = append(merged[:pick], merged[pick+1:]...)
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
