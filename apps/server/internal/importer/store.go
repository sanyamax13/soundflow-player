package importer

import (
	"context"

	"soundflow/server/internal/db"
)

// Store — то, что importer.Scan / Sweep требуют от базы. Раньше здесь стоял
// конкретный *db.Pool (PostgreSQL); интерфейс позволяет подставить и лёгкую
// SQLite-базу «сервера в одном exe» (см. internal/litestore). *db.Pool
// удовлетворяет этому интерфейсу без изменений.
type Store interface {
	Ping(ctx context.Context) error
	Migrate(ctx context.Context) error
	Close()
	TrackByKey(ctx context.Context, normKey string) (*db.CatalogTrack, error)
	InsertTrackWithFile(ctx context.Context, t db.NewTrack, f db.NewTrackFile) error
	DeleteTrackByKey(ctx context.Context, normKey string) error
	LegacyMarkKind(ctx context.Context, normKey string) (string, error)
	LegacyMarksInsert(ctx context.Context, marks map[string]db.LegacyMark) (int, error)
	DeleteLegacyMark(ctx context.Context, normKey string) error
	UpsertLegacyMark(ctx context.Context, m db.LegacyMark) error
	TracksForSweep(ctx context.Context) ([]db.SweepRow, error)
}
