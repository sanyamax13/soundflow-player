package db

import (
	"context"
	"time"
)

// Виды строк ленты «что делал сервер» (server_log). Человеческий текст —
// в поле Detail. Alex 06.09.2026, разбор плеера п.10/12.
const (
	LogAdded    = "added"     // добавил трек в каталог
	LogRemoved  = "removed"   // убрал трек (в bytes — размер стёртого файла)
	LogNotFound = "not_found" // искал, не нашёл
	LogReplaced = "replaced"  // заменил на версию получше
	LogError    = "error"     // ошибка
	LogInfo     = "info"      // прочее
)

// ServerLogRow — строка ленты действий сервера.
type ServerLogRow struct {
	ID     int64     `json:"id"`
	At     time.Time `json:"at"`
	Kind   string    `json:"kind"`
	Artist string    `json:"artist"`
	Title  string    `json:"title"`
	Detail string    `json:"detail"`
	Bytes  int64     `json:"bytes"`
}

// AddServerLog кладёт строку в ленту сервера. Лента вспомогательная —
// зовущий не обязан ронять основное действие из-за сбоя записи.
func (d *Pool) AddServerLog(ctx context.Context, kind, artist, title, detail string, bytes int64) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	_, err := d.p.Exec(ctx,
		`INSERT INTO server_log (kind, artist, title, detail, bytes) VALUES ($1, $2, $3, $4, $5)`,
		kind, artist, title, detail, bytes)
	return err
}

// RecentServerLog — последние строки ленты, новые сверху.
func (d *Pool) RecentServerLog(ctx context.Context, limit int) ([]ServerLogRow, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := d.p.Query(ctx, `
		SELECT id, at, kind, artist, title, detail, bytes
		FROM server_log ORDER BY at DESC, id DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ServerLogRow, 0, limit)
	for rows.Next() {
		var x ServerLogRow
		if err := rows.Scan(&x.ID, &x.At, &x.Kind, &x.Artist, &x.Title, &x.Detail, &x.Bytes); err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

// ServerReport — сводка ленты за N дней для экрана «Сервер» (пункт 12):
// добавлено / убрано / не нашёл / заменил на лучше / освободил место.
type ServerReport struct {
	Days       int       `json:"days"`
	Since      time.Time `json:"since"`
	Added      int64     `json:"added"`
	Removed    int64     `json:"removed"`
	NotFound   int64     `json:"not_found"`
	Replaced   int64     `json:"replaced"`
	Errors     int64     `json:"errors"`
	FreedBytes int64     `json:"freed_bytes"`
}

// ServerReportSince собирает сводку по server_log за последние days дней.
func (d *Pool) ServerReportSince(ctx context.Context, days int) (ServerReport, error) {
	rep := ServerReport{Days: days}
	if d == nil || d.p == nil {
		return rep, errNoDB
	}
	if days <= 0 {
		days = 30
	}
	rep.Days = days
	rep.Since = time.Now().Add(-time.Duration(days) * 24 * time.Hour)
	rows, err := d.p.Query(ctx, `
		SELECT kind, count(*), COALESCE(sum(bytes), 0)
		FROM server_log WHERE at >= $1 GROUP BY kind`, rep.Since)
	if err != nil {
		return rep, err
	}
	defer rows.Close()
	for rows.Next() {
		var k string
		var n, b int64
		if err := rows.Scan(&k, &n, &b); err != nil {
			return rep, err
		}
		switch k {
		case LogAdded:
			rep.Added = n
		case LogRemoved:
			rep.Removed = n
			rep.FreedBytes += b
		case LogNotFound:
			rep.NotFound = n
		case LogReplaced:
			rep.Replaced = n
		case LogError:
			rep.Errors = n
		}
	}
	return rep, rows.Err()
}
