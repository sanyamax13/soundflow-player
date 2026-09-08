package api

import (
	"context"
	"time"

	"soundflow/server/internal/db"
	"soundflow/server/internal/importer"
)

// Store — всё, что телефонный/админский HTTP-слой требует от базы. Раньше в
// Server.DB стоял конкретный *db.Pool (PostgreSQL). Через интерфейс тот же
// проверенный код обслуживает и лёгкую SQLite-базу «сервера в одном exe»
// (см. internal/litestore). *db.Pool удовлетворяет интерфейсу как есть.
//
// Встраивает importer.Store, потому что обработчики /v1/admin/import-library
// и /sweep-junk передают эту же базу в importer.Scan / importer.Sweep.
type Store interface {
	importer.Store

	CatalogList(ctx context.Context, limit int) ([]db.CatalogTrack, error)
	CatalogSearch(ctx context.Context, q string, limit int) ([]db.CatalogTrack, error)
	NextLibraryBatch(ctx context.Context, excludeIDs []string, budgetBytes int64) ([]db.CatalogTrack, int64, error)
	OrderBySimilarity(ctx context.Context, seedID string, candidateIDs []string) (ordered []string, reordered bool, err error)

	TrackFilePath(ctx context.Context, trackID string) (string, bool, error)
	TrackCoverURL(ctx context.Context, id string) (url string, found bool, err error)
	TrackWaveform(ctx context.Context, id string) (bars []byte, found bool, err error)
	TrackArtistTitle(ctx context.Context, trackID string) (artist, title string, ok bool, err error)
	TrackForDeletion(ctx context.Context, trackID string) (normKey, filePath string, ok bool, err error)
	DeleteTrack(ctx context.Context, trackID string) error

	TrashedTracks(ctx context.Context) ([]db.TrashedRow, error)
	ListBlocked(ctx context.Context, limit int) ([]db.BlockedRow, error)

	TrackIDsWithoutFeatures(ctx context.Context, limit int) ([]string, error)
	TracksMissingCoverURL(ctx context.Context, limit int) ([]db.CoverCandidate, error)
	SetCoverURL(ctx context.Context, id, url string) error

	SaveSync(ctx context.Context, dev db.Device, events []db.SyncEvent) ([]string, error)
	SyncReport(ctx context.Context, deviceID string) (lastSync *time.Time, total int64, err error)

	AddServerLog(ctx context.Context, kind, artist, title, detail string, bytes int64) error
	RecentServerLog(ctx context.Context, limit int) ([]db.ServerLogRow, error)
	RecentEvents(ctx context.Context, limit int) ([]db.EventInfo, error)
	ListDevices(ctx context.Context) ([]db.DeviceInfo, error)
	AdminStatus(ctx context.Context) (db.AdminStatus, error)
	ServerReportSince(ctx context.Context, days int) (db.ServerReport, error)
}
