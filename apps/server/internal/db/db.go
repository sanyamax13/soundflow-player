package db

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

// errNoDB — база не подключена (сервер поднялся до docker compose up).
var errNoDB = errors.New("база не подключена")

// Pool — обёртка над пулом соединений к PostgreSQL.
type Pool struct {
	p *pgxpool.Pool
}

// Open подключается к базе. Ошибку не глотаем, но сервер может стартовать и без
// базы (health честно покажет, что база недоступна) — так каркас запускается
// до docker compose up.
func Open(ctx context.Context, url string) (*Pool, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = 4
	p, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return &Pool{p: p}, nil
}

// Ping — жив ли коннект к базе прямо сейчас.
func (d *Pool) Ping(ctx context.Context) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	return d.p.Ping(ctx)
}

func (d *Pool) Close() {
	if d != nil && d.p != nil {
		d.p.Close()
	}
}

// Migrate накатывает встроенные .sql-файлы из migrations/ по порядку имён.
// Применённое отмечается в schema_migrations, повторно не гоняется.
func (d *Pool) Migrate(ctx context.Context) error {
	if d == nil || d.p == nil {
		return errNoDB
	}
	// Advisory-lock: сериализует накат, если несколько процессов/тестов стартуют
	// разом на одну базу. Автоснимается при закрытии сессии.
	conn, err := d.p.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock(838201)`); err != nil {
		return err
	}
	defer conn.Exec(ctx, `SELECT pg_advisory_unlock(838201)`) //nolint:errcheck

	if _, err := conn.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version    text PRIMARY KEY,
			applied_at timestamptz NOT NULL DEFAULT now()
		)`); err != nil {
		return err
	}

	entries, err := migrationFS.ReadDir("migrations")
	if err != nil {
		return err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	for _, name := range names {
		var done bool
		if err := d.p.QueryRow(ctx,
			`SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = $1)`, name,
		).Scan(&done); err != nil {
			return err
		}
		if done {
			continue
		}
		body, err := migrationFS.ReadFile("migrations/" + name)
		if err != nil {
			return err
		}
		tx, err := d.p.Begin(ctx)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, string(body)); err != nil {
			_ = tx.Rollback(ctx)
			return fmt.Errorf("миграция %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO schema_migrations(version) VALUES($1) ON CONFLICT (version) DO NOTHING`, name); err != nil {
			_ = tx.Rollback(ctx)
			return err
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		log.Printf("миграция применена: %s", name)
	}
	return nil
}

// Device — телефон, приславший события.
type Device struct {
	ID         string
	Name       string
	AppVersion string
	MusicBytes int64
	Transport  string // wifi | ethernet | mobile | vpn | ""
}

// SyncEvent — одно событие из очереди телефона. Дедуп по UUID.
type SyncEvent struct {
	UUID     string          `json:"uuid"`
	Kind     string          `json:"kind"`
	TrackID  string          `json:"track_id"`
	Payload  json.RawMessage `json:"payload"`
	ClientTS int64           `json:"ts"`
}

// SaveSync в одной транзакции обновляет устройство и вставляет события.
// Возвращает uuid действительно новых событий (дубли молча пропускаются).
func (d *Pool) SaveSync(ctx context.Context, dev Device, events []SyncEvent) ([]string, error) {
	if d == nil || d.p == nil {
		return nil, errNoDB
	}
	tx, err := d.p.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // после Commit — no-op

	if _, err := tx.Exec(ctx, `
		INSERT INTO devices (id, name, app_version, music_bytes, last_sync_at)
		VALUES ($1, $2, $3, $4, now())
		ON CONFLICT (id) DO UPDATE SET
			name         = EXCLUDED.name,
			app_version  = EXCLUDED.app_version,
			music_bytes  = EXCLUDED.music_bytes,
			last_sync_at = now()`,
		dev.ID, dev.Name, dev.AppVersion, dev.MusicBytes,
	); err != nil {
		return nil, err
	}

	accepted := make([]string, 0, len(events))
	for _, e := range events {
		payload := e.Payload
		if len(payload) == 0 {
			payload = json.RawMessage("{}")
		}
		var got string
		err := tx.QueryRow(ctx, `
			INSERT INTO sync_events (event_uuid, device_id, kind, track_id, payload, client_ts)
			VALUES ($1, $2, $3, $4, $5, $6)
			ON CONFLICT (event_uuid) DO NOTHING
			RETURNING event_uuid`,
			e.UUID, dev.ID, e.Kind, e.TrackID, payload, e.ClientTS,
		).Scan(&got)
		if errors.Is(err, pgx.ErrNoRows) {
			continue // дубль — событие уже было
		}
		if err != nil {
			return nil, err
		}
		accepted = append(accepted, got)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return accepted, nil
}

// SyncReport — данные для карточки «Синхронизация»: когда синхронились и
// сколько всего событий сервер принял с этого телефона.
func (d *Pool) SyncReport(ctx context.Context, deviceID string) (lastSync *time.Time, total int64, err error) {
	if d == nil || d.p == nil {
		return nil, 0, errNoDB
	}
	err = d.p.QueryRow(ctx, `
		SELECT (SELECT last_sync_at FROM devices WHERE id = $1),
		       (SELECT count(*) FROM sync_events WHERE device_id = $1)`,
		deviceID,
	).Scan(&lastSync, &total)
	return lastSync, total, err
}
