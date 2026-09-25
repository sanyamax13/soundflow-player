package localdb

// TrackEnergies — средняя громкость 0..1 по каждому треку с уже посчитанным
// waveform (wavekeeper.go, все 11662 песни готовы на 24.09.2026). Грубая
// метрика «спокойное/энергичное» для фильтра радио на телефоне (Alex TG
// 25.09.2026: «настроение»). Waveform уже посчитан для всей библиотеки —
// отдельного прохода по звуку не делаем, просто усредняем готовые байты
// (0..255) на каждый запрос каталога; треков мало и байт на трек мало,
// секунды не занимает.
func (d *DB) TrackEnergies() (map[string]float64, error) {
	rows, err := d.sql.Query(`SELECT id, waveform FROM tracks WHERE waveform IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]float64)
	for rows.Next() {
		var id string
		var wf []byte
		if err := rows.Scan(&id, &wf); err != nil {
			return nil, err
		}
		if len(wf) == 0 {
			continue
		}
		var sum int
		for _, b := range wf {
			sum += int(b)
		}
		out[id] = float64(sum) / float64(len(wf)) / 255.0
	}
	return out, rows.Err()
}
