package localdb

import "sort"

// TasteReviewTrack — трек в очереди на разбор коллекции (Alex TG
// 25.09.2026: «пройдись по всем песням и подскажи, что моё, что нет»).
// Проверка на реальных данных показала: звук почти не отличает
// «не нравится» (точность 61-62%, см. dislikeguard.go), история
// забракованных исполнителей покрывает единицы треков, а фидбек вообще
// есть только у 8% каталога — значит ЖЁСТКУЮ метку «не моё» ставить
// нечестно. Вместо трёх корзин — один список, отсортированный от «больше
// всего похоже на то, что тебе обычно нравится» к «меньше всего» (Alex TG
// 25.09.2026, второй заход: «пускай сверху будет то, что нравится больше,
// снизу — то, что не нравится, буду слушать и постепенно доходить до
// низа и удалять» — начинать с вероятно понравившегося приятнее, чем с
// заведомо чужого).
type TasteReviewTrack struct {
	ID     string  `json:"id"`
	Artist string  `json:"artist"`
	Title  string  `json:"title"`
	Album  string  `json:"album"`
	Score  float64 `json:"score"` // близость к вкусу 0..1 (ScoreTracksByTaste), ниже — менее типично
}

// TasteReviewQueue — все треки библиотеки с живым файлом, КРОМЕ уже решённых
// (избранное/лайк/дизлайк — Alex их уже разобрал, пересматривать незачем),
// отсортированные по УБЫВАНИЮ похожести на вкус — начало списка вероятнее
// понравится. Нет центров вкуса (мало данных для кластеров) → пустой
// список, не ошибка — рано ещё.
func (d *DB) TasteReviewQueue(limit int) ([]TasteReviewTrack, error) {
	if limit <= 0 || limit > 20000 {
		limit = 20000
	}
	rows, err := d.sql.Query(`
		SELECT t.id, t.artist, t.title, t.album,
		       COALESCE(lm.kind, '') AS mark,
		       COALESCE((SELECT SUM(value) FROM feedback_event WHERE track_id = t.id), 0) AS fb
		FROM tracks t
		JOIN track_files tf ON tf.track_id = t.id AND tf.rejected = 0
		LEFT JOIN legacy_marks lm ON lm.normalized_key = t.normalized_key
		GROUP BY t.id`)
	if err != nil {
		return nil, err
	}
	type row struct{ id, artist, title, album string }
	var pending []row
	for rows.Next() {
		var r row
		var mark string
		var fb float64
		if err := rows.Scan(&r.id, &r.artist, &r.title, &r.album, &mark, &fb); err != nil {
			rows.Close()
			return nil, err
		}
		decided := mark == "favorite" || mark == "blocked" || fb != 0
		if !decided {
			pending = append(pending, r)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	ids := make([]string, len(pending))
	for i, r := range pending {
		ids[i] = r.id
	}
	scores, err := d.ScoreTracksByTaste(ids)
	if err != nil {
		return nil, err
	}

	out := make([]TasteReviewTrack, 0, len(pending))
	for _, r := range pending {
		s, ok := scores[r.id]
		if !ok {
			continue // нет центров вкуса ещё — рано сортировать
		}
		out = append(out, TasteReviewTrack{ID: r.id, Artist: r.artist, Title: r.title, Album: r.album, Score: s})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Score > out[j].Score })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
