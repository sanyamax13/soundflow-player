package db

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Pool — обёртка над пулом соединений к PostgreSQL.
// На этапе каркаса нужна только проверка «база на связи».
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
		return context.Canceled
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
