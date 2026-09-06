package db

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

// LegacyMark — одна запись разметки со старого плеера.
type LegacyMark struct {
	Key    string
	Kind   string // "favorite" | "blocked"
	Artist string
	Title  string
	At     time.Time
}

// LegacyMarkCount — сколько записей в legacy_marks (0 → ещё не засеяно).
func (d *Pool) LegacyMarkCount(ctx context.Context) (int, error) {
	if d == nil || d.p == nil {
		return 0, errNoDB
	}
	var n int
	err := d.p.QueryRow(ctx, `SELECT count(*) FROM legacy_marks`).Scan(&n)
	return n, err
}

// LegacyMarksInsert — пакетная вставка (ON CONFLICT DO NOTHING; вызывающий сам
// разрешает favorite/blocked до вызова). Возвращает число реально вставленных.
func (d *Pool) LegacyMarksInsert(ctx context.Context, marks map[string]LegacyMark) (int, error) {
	if d == nil || d.p == nil {
		return 0, errNoDB
	}
	if len(marks) == 0 {
		return 0, nil
	}
	tx, err := d.p.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	n := 0
	for _, m := range marks {
		var at any
		if !m.At.IsZero() {
			at = m.At
		}
		ct, err := tx.Exec(ctx, `
			INSERT INTO legacy_marks (normalized_key, kind, artist, title, marked_at)
			VALUES ($1,$2,$3,$4,$5)
			ON CONFLICT (normalized_key) DO NOTHING`,
			m.Key, m.Kind, m.Artist, m.Title, at)
		if err != nil {
			return 0, err
		}
		n += int(ct.RowsAffected())
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return n, nil
}

// UpsertLegacyMark — поставить/перезаписать метку одного ключа (в отличие от
// LegacyMarksInsert — не DO NOTHING, а именно перезаписывает kind). Для живых
// событий с телефона (например, delete должен победить более раннее favorite).
func (d *Pool) UpsertLegacyMark(ctx context.Context, m LegacyMark) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	var at any
	if !m.At.IsZero() {
		at = m.At
	}
	_, err := d.p.Exec(ctx, `
		INSERT INTO legacy_marks (normalized_key, kind, artist, title, marked_at)
		VALUES ($1,$2,$3,$4,$5)
		ON CONFLICT (normalized_key) DO UPDATE SET
			kind = EXCLUDED.kind, artist = EXCLUDED.artist, title = EXCLUDED.title, marked_at = EXCLUDED.marked_at`,
		m.Key, m.Kind, m.Artist, m.Title, at)
	return err
}

// DeleteLegacyMark — убрать метку по ключу (для «вернуть в каталог» и тестов).
func (d *Pool) DeleteLegacyMark(ctx context.Context, normKey string) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	_, err := d.p.Exec(ctx, `DELETE FROM legacy_marks WHERE normalized_key = $1`, normKey)
	return err
}

// TrashedRow — трек в «Корзине»: был в каталоге, убран (удалён с телефона
// или зачищен как мусор), файл лежит в _trash, можно вернуть.
type TrashedRow struct {
	TrackID  string     `json:"track_id"`
	Artist   string     `json:"artist"`
	Title    string     `json:"title"`
	NormKey  string     `json:"-"`
	MarkedAt *time.Time `json:"marked_at,omitempty"`
}

// TrashedTracks — всё, что сейчас blocked И при этом ЕСТЬ в каталоге (т.е.
// раньше было доступно, а не старая метка из чёрного списка старого плеера
// без своего трека). Именно это можно осмысленно «вернуть» — файл лежит в
// _trash, ждёт.
func (d *Pool) TrashedTracks(ctx context.Context) ([]TrashedRow, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	rows, err := d.p.Query(ctx, `
		SELECT t.id, t.artist, t.title, t.normalized_key, lm.marked_at
		FROM legacy_marks lm
		JOIN tracks t ON t.normalized_key = lm.normalized_key
		WHERE lm.kind = 'blocked'
		ORDER BY lm.marked_at DESC NULLS LAST`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]TrashedRow, 0)
	for rows.Next() {
		var r TrashedRow
		var at *time.Time
		if err := rows.Scan(&r.TrackID, &r.Artist, &r.Title, &r.NormKey, &at); err != nil {
			return nil, err
		}
		r.MarkedAt = at
		out = append(out, r)
	}
	return out, rows.Err()
}

// BlockedRow — одна запись списка «больше не качать» для экрана «Сервер».
// Artist/Title берём из tracks, если трек ещё в каталоге; иначе — из самой
// метки (у старого чёрного списка они там есть), иначе пусто.
type BlockedRow struct {
	Key    string     `json:"key"`
	Artist string     `json:"artist"`
	Title  string     `json:"title"`
	InCat  bool       `json:"in_catalog"`
	At     *time.Time `json:"at,omitempty"`
}

// ListBlocked — весь список «больше не качать» (kind='blocked'), новые сверху.
// limit ≤ 0 — без ограничения.
func (d *Pool) ListBlocked(ctx context.Context, limit int) ([]BlockedRow, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	sql := `
		SELECT lm.normalized_key,
		       COALESCE(NULLIF(t.artist,''), lm.artist) AS artist,
		       COALESCE(NULLIF(t.title,''),  lm.title)  AS title,
		       (t.id IS NOT NULL) AS in_catalog,
		       lm.marked_at
		FROM legacy_marks lm
		LEFT JOIN tracks t ON t.normalized_key = lm.normalized_key
		WHERE lm.kind = 'blocked'
		ORDER BY lm.marked_at DESC NULLS LAST, lm.normalized_key`
	if limit > 0 {
		sql += "\n\t\tLIMIT " + strconv.Itoa(limit)
	}
	rows, err := d.p.Query(ctx, sql)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]BlockedRow, 0)
	for rows.Next() {
		var r BlockedRow
		var at *time.Time
		if err := rows.Scan(&r.Key, &r.Artist, &r.Title, &r.InCat, &at); err != nil {
			return nil, err
		}
		r.At = at
		out = append(out, r)
	}
	return out, rows.Err()
}

// LegacyMarkKind — "favorite" / "blocked" / "" для ключа.
func (d *Pool) LegacyMarkKind(ctx context.Context, normKey string) (string, error) {
	if d == nil || d.p == nil {
		return "", errNoDB
	}
	var kind string
	err := d.p.QueryRow(ctx, `SELECT kind FROM legacy_marks WHERE normalized_key = $1`, normKey).Scan(&kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return kind, nil
}
