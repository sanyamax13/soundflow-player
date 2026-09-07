package acquire

import (
	"context"

	"soundflow/server/internal/db"
)

// Store — что acquire.Service требует от базы. Раньше поле DB было конкретным
// *db.Pool (PostgreSQL); через интерфейс сюда же подставляется лёгкая
// SQLite-база «сервера в одном exe» (см. internal/litestore). *db.Pool
// удовлетворяет интерфейсу без изменений.
type Store interface {
	TrackByKey(ctx context.Context, normKey string) (*db.CatalogTrack, error)
	TrackFilePath(ctx context.Context, trackID string) (string, bool, error)
	InsertTrackWithFile(ctx context.Context, t db.NewTrack, f db.NewTrackFile) error
	SetFeatureVector(ctx context.Context, trackID string, v []float32) error
	LegacyMarkKind(ctx context.Context, normKey string) (string, error)
	RecordRejected(ctx context.Context, normKey, sourceURL, provider, artist, title, reason string) error
}
