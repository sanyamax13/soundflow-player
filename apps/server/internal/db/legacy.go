package db

import (
	"context"
	"errors"
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

// DeleteLegacyMark — убрать метку по ключу (для «вернуть в каталог» и тестов).
func (d *Pool) DeleteLegacyMark(ctx context.Context, normKey string) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	_, err := d.p.Exec(ctx, `DELETE FROM legacy_marks WHERE normalized_key = $1`, normKey)
	return err
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
