package localdb

import (
	"database/sql"
	"encoding/json"
	"time"
)

// «Обучение вкусу», этап 2 (docs/TASTE-PLAN.md): производные из sync_events
// сигналы вкуса. Храним события с типом и весом-концептом; итоговые оценки —
// суммы, пересчитываются на чтении (декей и слои — этапы дальше).

// deriveFeedback переводит событие телефона в сигнал вкуса. ok=false —
// событие к вкусу отношения не имеет (play, download, rename).
func deriveFeedback(kind string, payload json.RawMessage, reason string) (eventType string, value float64, ok bool) {
	switch kind {
	case "like":
		return "like", 5, true
	case "unlike":
		return "unlike", 0, true // событие храним, в оценку пока не вносим
	case "dislike":
		return "dislike", -5, true
	case "complete":
		return "finish", 1.5, true
	case "skip":
		pos, dur := skipPosition(payload)
		if dur > 0 && float64(pos)/float64(dur) < 0.15 {
			return "skip_early", -0.7, true
		}
		if dur <= 0 && pos > 0 && pos < 20000 {
			return "skip_early", -0.7, true
		}
		return "skip_normal", -0.3, true
	case "delete":
		switch reason {
		case "bad_quality", "wrong_version":
			return "delete_bad_version", 0, true // сигнал качеству, не вкусу
		case "dup", "duplicate":
			return "delete_dup", 0, true
		default:
			return "delete_not_my_taste", -5, true
		}
	}
	return "", 0, false
}

func skipPosition(p json.RawMessage) (posMS, durMS int64) {
	if len(p) == 0 {
		return 0, 0
	}
	var v struct {
		PositionMS int64 `json:"position_ms"`
		DurationMS int64 `json:"duration_ms"`
	}
	_ = json.Unmarshal(p, &v)
	return v.PositionMS, v.DurationMS
}

func eventReason(p json.RawMessage) string {
	if len(p) == 0 {
		return ""
	}
	var v struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(p, &v)
	return v.Reason
}

// recordFeedback вставляет сигнал вкуса в рамках уже открытой транзакции
// SaveSync. Артиста берём из каталога по track_id. Ошибку глотаем — лента
// вкуса вспомогательная, основную вставку события из-за неё не рушим.
func recordFeedback(tx *sql.Tx, eventUUID, deviceID, trackID string, kind string, payload json.RawMessage, now string, clientTS int64) {
	et, val, ok := deriveFeedback(kind, payload, eventReason(payload))
	if !ok {
		return
	}
	var artist string
	if trackID != "" {
		_ = tx.QueryRow(`SELECT artist FROM tracks WHERE id = ?`, trackID).Scan(&artist)
	}
	_, _ = tx.Exec(`
		INSERT INTO feedback_event
			(event_uuid, device_id, track_id, artist, event_type, value, reason, client_ts, created_at)
		VALUES (?,?,?,?,?,?,?,?,?)
		ON CONFLICT(event_uuid) DO NOTHING`,
		eventUUID, deviceID, trackID, artist, et, val, eventReason(payload), clientTS, now)
}

// TasteRow — строка «топа вкуса» (артист или трек).
type TasteRow struct {
	ID     string  `json:"id,omitempty"`
	Artist string  `json:"artist"`
	Title  string  `json:"title,omitempty"`
	Score  float64 `json:"score"`
	Events int     `json:"events"`
	Pos    int     `json:"pos"`
	Neg    int     `json:"neg"`
}

// TasteTotals — сводка для вкладки «Вкус» в окне.
type TasteTotals struct {
	Events   int `json:"events"`
	Likes    int `json:"likes"`
	Dislikes int `json:"dislikes"`
	Skips    int `json:"skips"`
	Finishes int `json:"finishes"`
	Deletes  int `json:"deletes"`
	Artists  int `json:"artists"`
}

const tasteArtistSelect = `
	SELECT artist,
	       SUM(value) AS score,
	       COUNT(*) AS n,
	       SUM(CASE WHEN value > 0 THEN 1 ELSE 0 END) AS pos,
	       SUM(CASE WHEN value < 0 THEN 1 ELSE 0 END) AS neg
	FROM feedback_event
	WHERE artist <> ''
	GROUP BY artist`

func (d *DB) scanTasteArtists(rows *sql.Rows) ([]TasteRow, error) {
	defer rows.Close()
	out := make([]TasteRow, 0)
	for rows.Next() {
		var r TasteRow
		if err := rows.Scan(&r.Artist, &r.Score, &r.Events, &r.Pos, &r.Neg); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// TasteArtists — топ (по вкусу) и антитоп (что не заходит) исполнителей.
func (d *DB) TasteArtists(limit int) (top, bottom []TasteRow, err error) {
	if limit <= 0 {
		limit = 15
	}
	tr, err := d.sql.Query(tasteArtistSelect+` HAVING score > 0 ORDER BY score DESC LIMIT ?`, limit)
	if err != nil {
		return nil, nil, err
	}
	if top, err = d.scanTasteArtists(tr); err != nil {
		return nil, nil, err
	}
	br, err := d.sql.Query(tasteArtistSelect+` HAVING score < 0 ORDER BY score ASC LIMIT ?`, limit)
	if err != nil {
		return nil, nil, err
	}
	if bottom, err = d.scanTasteArtists(br); err != nil {
		return nil, nil, err
	}
	return top, bottom, nil
}

const tasteTrackSelect = `
	SELECT fe.track_id, t.artist, t.title,
	       SUM(fe.value) AS score, COUNT(*) AS n,
	       SUM(CASE WHEN fe.value > 0 THEN 1 ELSE 0 END) AS pos,
	       SUM(CASE WHEN fe.value < 0 THEN 1 ELSE 0 END) AS neg
	FROM feedback_event fe
	JOIN tracks t ON t.id = fe.track_id
	WHERE fe.track_id <> ''
	GROUP BY fe.track_id`

func (d *DB) scanTasteTracks(rows *sql.Rows) ([]TasteRow, error) {
	defer rows.Close()
	out := make([]TasteRow, 0)
	for rows.Next() {
		var r TasteRow
		if err := rows.Scan(&r.ID, &r.Artist, &r.Title, &r.Score, &r.Events, &r.Pos, &r.Neg); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// TasteTracks — топ и антитоп треков.
func (d *DB) TasteTracks(limit int) (top, bottom []TasteRow, err error) {
	if limit <= 0 {
		limit = 20
	}
	tr, err := d.sql.Query(tasteTrackSelect+` HAVING score > 0 ORDER BY score DESC LIMIT ?`, limit)
	if err != nil {
		return nil, nil, err
	}
	if top, err = d.scanTasteTracks(tr); err != nil {
		return nil, nil, err
	}
	br, err := d.sql.Query(tasteTrackSelect+` HAVING score < 0 ORDER BY score ASC LIMIT ?`, limit)
	if err != nil {
		return nil, nil, err
	}
	if bottom, err = d.scanTasteTracks(br); err != nil {
		return nil, nil, err
	}
	return top, bottom, nil
}

// TasteTotals — сводные счётчики.
func (d *DB) TasteTotals() (TasteTotals, error) {
	var t TasteTotals
	// COALESCE — на пустой таблице SUM(...) даёт NULL, скан в int падает.
	err := d.sql.QueryRow(`
		SELECT
			COUNT(*),
			COALESCE(SUM(CASE WHEN event_type = 'like' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN event_type IN ('dislike','delete_not_my_taste') THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN event_type IN ('skip_early','skip_normal') THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN event_type = 'finish' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN event_type LIKE 'delete_%' THEN 1 ELSE 0 END), 0),
			COUNT(DISTINCT NULLIF(artist,''))
		FROM feedback_event`,
	).Scan(&t.Events, &t.Likes, &t.Dislikes, &t.Skips, &t.Finishes, &t.Deletes, &t.Artists)
	return t, err
}

// RebuildFeedback — разово пересобрать feedback_event из всей истории
// sync_events (для баз, где события копились до появления «вкуса»).
// Дедуп по event_uuid — повторный вызов безопасен. Возвращает число строк
// в таблице после пересборки.
func (d *DB) RebuildFeedback() (int, error) {
	rows, err := d.sql.Query(`
		SELECT event_uuid, device_id, kind, track_id, payload, client_ts, COALESCE(applied_at,'')
		FROM sync_events
		WHERE kind IN ('like','unlike','dislike','skip','complete','delete')
		ORDER BY applied_at`)
	if err != nil {
		return 0, err
	}
	type row struct {
		uuid, dev, kind, track, payload, at string
		ts                                  int64
	}
	var batch []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.uuid, &r.dev, &r.kind, &r.track, &r.payload, &r.ts, &r.at); err != nil {
			rows.Close()
			return 0, err
		}
		batch = append(batch, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	tx, err := d.sql.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback() //nolint:errcheck
	for _, r := range batch {
		at := r.at
		if at == "" {
			at = time.Now().UTC().Format(time.RFC3339Nano)
		}
		recordFeedback(tx, r.uuid, r.dev, r.track, r.kind, json.RawMessage(r.payload), at, r.ts)
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	var n int
	_ = d.sql.QueryRow(`SELECT COUNT(*) FROM feedback_event`).Scan(&n)
	return n, nil
}
