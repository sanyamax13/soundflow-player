package localdb

import "time"

// «Сессия» (TASTE-PLAN §3): что нравится прямо сейчас. НЕ хранится в
// taste_cluster — считается на лету, слишком мало данных для k-means и
// должен реагировать мгновенно. Берём только явные лайки (НЕ `finish` —
// finish срабатывает на каждой доигранной в радио песне, т.е. в режиме
// радио сессия собиралась бы из того, что радио само же и поставило —
// самоподкрепляющаяся петля). Максимум 5, не усредняем (TASTE-PLAN §3 п.4
// «не один центр — среднее по жанрам каша»): каждый лайк — свой вектор,
// tasteAffinity сама возьмёт максимум косинуса.
//
// Время — client_ts (часы ТЕЛЕФОНА), не created_at (время сервера): если
// телефон был без сети несколько дней, весь батч ляжет с created_at≈сейчас,
// и старые лайки стали бы «текущей сессией». Защита от кривых часов
// телефона: игнорируем client_ts из будущего или старше суток.
const (
	sessionWindow    = 2 * time.Hour
	sessionMaxEvents = 5
)

func (d *DB) sessionVectors() ([][]float32, error) {
	now := time.Now()
	cutoffMs := now.Add(-sessionWindow).UnixMilli()
	futureMs := now.UnixMilli()
	dayAgoMs := now.Add(-24 * time.Hour).UnixMilli()

	rows, err := d.sql.Query(`
		SELECT t.feature_vector
		FROM feedback_event fe
		JOIN tracks t ON t.id = fe.track_id
		WHERE fe.event_type = 'like'
		  AND fe.client_ts >= ? AND fe.client_ts <= ?
		  AND t.feature_vector IS NOT NULL
		ORDER BY fe.client_ts DESC
		LIMIT ?`,
		maxInt64(cutoffMs, dayAgoMs), futureMs, sessionMaxEvents)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][]float32
	for rows.Next() {
		var blob []byte
		if err := rows.Scan(&blob); err != nil {
			return nil, err
		}
		if v := blobToVec(blob); len(v) > 0 {
			out = append(out, l2norm(v))
		}
	}
	return out, rows.Err()
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
