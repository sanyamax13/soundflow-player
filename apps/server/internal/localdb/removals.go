package localdb

import (
	"database/sql"
	"errors"
	"time"
)

// PendingRemoval — песня, убранная на телефоне, файл которой на компьютере
// ждёт подтверждения в окне программы (Alex TG 19943/19948, 19.09.2026: «при
// синхронизации программа выводит окно, где убранные, я подтверждаю — они
// стираются с ПК, как по Shift+Delete»). Метка «больше не качать» на такой
// трек уже поставлена приёмом события; здесь только то, что надо стереть.
type PendingRemoval struct {
	TrackID  string `json:"track_id"`
	Artist   string `json:"artist"`
	Title    string `json:"title"`
	FilePath string `json:"-"` // канонический путь, как в БД; наружу не отдаём
	Bytes    int64  `json:"bytes"`
	Reason   string `json:"reason"`
	AddedAt  string `json:"added_at"`
}

// AddPendingRemoval ставит песню в ожидание. Повтор по тому же треку ничего не
// меняет (событие уже принято раньше).
func (d *DB) AddPendingRemoval(p PendingRemoval) error {
	if p.TrackID == "" {
		return errors.New("пустой track_id")
	}
	if p.AddedAt == "" {
		p.AddedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}
	_, err := d.sql.Exec(`
		INSERT INTO pending_removals (track_id, artist, title, file_path, bytes, reason, added_at)
		VALUES (?,?,?,?,?,?,?)
		ON CONFLICT(track_id) DO NOTHING`,
		p.TrackID, p.Artist, p.Title, p.FilePath, p.Bytes, p.Reason, p.AddedAt)
	return err
}

// PendingRemovals — всё, что ждёт подтверждения: старые сверху.
func (d *DB) PendingRemovals() ([]PendingRemoval, error) {
	rows, err := d.sql.Query(`
		SELECT track_id, artist, title, file_path, bytes, reason, added_at
		FROM pending_removals ORDER BY added_at, track_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]PendingRemoval, 0)
	for rows.Next() {
		var p PendingRemoval
		if err := rows.Scan(&p.TrackID, &p.Artist, &p.Title, &p.FilePath, &p.Bytes, &p.Reason, &p.AddedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// PendingRemoval — одна ожидающая песня (ok=false, если уже разобрана).
func (d *DB) PendingRemoval(trackID string) (PendingRemoval, bool, error) {
	var p PendingRemoval
	err := d.sql.QueryRow(`
		SELECT track_id, artist, title, file_path, bytes, reason, added_at
		FROM pending_removals WHERE track_id = ?`, trackID,
	).Scan(&p.TrackID, &p.Artist, &p.Title, &p.FilePath, &p.Bytes, &p.Reason, &p.AddedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return PendingRemoval{}, false, nil
	}
	if err != nil {
		return PendingRemoval{}, false, err
	}
	return p, true, nil
}

// DeletePendingRemoval убирает песню из ожидания (файл уже стёрт).
func (d *DB) DeletePendingRemoval(trackID string) error {
	_, err := d.sql.Exec(`DELETE FROM pending_removals WHERE track_id = ?`, trackID)
	return err
}
