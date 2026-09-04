// Package acquire — «найти и скачать трек»: дёргает Python-сайдкар (Яндекс 320 →
// musify → торренты), прогоняет результат через правила качества (этап 5) и
// кладёт в каталог. YouTube и Soulseek не вызываем (Alex, TG 17999).
package acquire

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	"soundflow/server/internal/db"
	"soundflow/server/internal/quality"
	"soundflow/server/internal/sidecar"
)

// Всегда гасим эти источники в цепочке сайдкара.
var skipProviders = []string{"soundcloud", "youtube_music", "youtube", "soulseek"}

var (
	ErrRejected   = errors.New("трек отклонён правилами (концерт/караоке/мусор)")
	ErrNotFound   = errors.New("ни один источник не дал файл")
	ErrLowQuality = errors.New("нашёлся только файл плохого качества")
	ErrWrongTrack = errors.New("источник отдал не тот трек")
)

// Finder — то, что умеет сайдкар (для подмены в тестах).
type Finder interface {
	FindAudio(ctx context.Context, artist, title string, expectedDurationSec int, skip []string) (sidecar.FindAudioResult, error)
	ID3Info(ctx context.Context, canonicalPath string) (artist, title string, err error)
	YandexTrackCover(ctx context.Context, artist, title string) (string, error)
}

type Service struct {
	DB     *db.Pool
	Finder Finder
}

type Request struct {
	Artist              string
	Title               string
	ExpectedDurationSec int
}

type Result struct {
	TrackID     string `json:"track_id"`
	Created     bool   `json:"created"` // false — трек уже был в каталоге
	Source      string `json:"source"`
	QualityTier string `json:"quality_tier"`
	Reason      string `json:"reason,omitempty"`
}

func (s *Service) Acquire(ctx context.Context, req Request) (Result, error) {
	// 1. Отсев по названию (концерт/караоке/мусор) — не тратим цепочку на мусор.
	if v := quality.Screen(req.Artist, req.Title, ""); !v.OK {
		return Result{Reason: v.Reason}, ErrRejected
	}

	normKey := quality.NormalizedKey(req.Artist, req.Title)

	// 2. Уже в каталоге?
	if existing, err := s.DB.TrackByKey(ctx, normKey); err != nil {
		return Result{}, err
	} else if existing != nil {
		return Result{TrackID: existing.ID, Created: false, Source: "catalog"}, nil
	}

	// 3. Найти и скачать через сайдкар.
	res, err := s.Finder.FindAudio(ctx, req.Artist, req.Title, req.ExpectedDurationSec, skipProviders)
	if err != nil {
		return Result{}, fmt.Errorf("сайдкар: %w", err)
	}
	if !res.Found || res.FilePath == "" {
		return Result{}, ErrNotFound
	}

	// 4. Тот ли трек? Торренты-альбомы иногда отдают файл из чужого альбома —
	//    сверяем артиста/название по тегам (если теги есть).
	id3Artist, id3Title, _ := s.Finder.ID3Info(ctx, res.FilePath)
	if id3Artist != "" && !looseMatch(req.Artist, id3Artist) {
		reason := fmt.Sprintf("в файле артист %q, просили %q", id3Artist, req.Artist)
		_ = s.DB.RecordRejected(ctx, normKey, res.ProviderURL, res.Source, req.Artist, req.Title, reason)
		return Result{Reason: reason}, ErrWrongTrack
	}
	if id3Title != "" && id3Artist != "" && !looseMatch(req.Title, id3Title) {
		reason := fmt.Sprintf("в файле трек %q, просили %q", id3Title, req.Title)
		_ = s.DB.RecordRejected(ctx, normKey, res.ProviderURL, res.Source, req.Artist, req.Title, reason)
		return Result{Reason: reason}, ErrWrongTrack
	}

	// 5. Качество файла.
	mime := quality.MimeFromExt(res.FilePath)
	tier, playable, why := quality.ClassifyAudio(mime, res.BitrateKbps)
	if !playable {
		_ = s.DB.RecordRejected(ctx, normKey, res.ProviderURL, res.Source, req.Artist, req.Title, why)
		return Result{Reason: why}, ErrLowQuality
	}

	// 6. Длительность (если знаем эталон).
	if req.ExpectedDurationSec > 0 && res.DurationSec > 0 {
		trusted := res.Source != "musify" && res.Source != "yandex" // торренты — доверенные для ремастера
		if dm := quality.DurationMatch(req.ExpectedDurationSec, res.DurationSec, trusted, false); !dm.OK {
			_ = s.DB.RecordRejected(ctx, normKey, res.ProviderURL, res.Source, req.Artist, req.Title, dm.Reason)
			return Result{Reason: dm.Reason}, ErrLowQuality
		}
	}

	// 7. Обложка (не критично).
	coverURL, _ := s.Finder.YandexTrackCover(ctx, req.Artist, req.Title)

	// 8. В каталог.
	trackID := "t_" + randID()
	fileID := "f_" + randID()
	if err := s.DB.InsertTrackWithFile(ctx,
		db.NewTrack{
			ID:            trackID,
			Artist:        req.Artist,
			Title:         req.Title,
			DurationSec:   res.DurationSec,
			ReleaseKind:   quality.ReleaseKind(req.Title, ""),
			Explicit:      quality.IsExplicit(req.Title),
			IsAltVersion:  quality.IsAltVersion(req.Title),
			NormalizedKey: normKey,
			CoverURL:      coverURL,
		},
		db.NewTrackFile{
			ID:            fileID,
			NormalizedKey: normKey,
			FilePath:      res.FilePath,
			MimeType:      mime,
			BitrateKbps:   res.BitrateKbps,
			SizeBytes:     res.SizeBytes,
			DurationSec:   res.DurationSec,
			Source:        res.Source,
			QualityTier:   tier.String(),
		},
	); err != nil {
		return Result{}, err
	}

	return Result{TrackID: trackID, Created: true, Source: res.Source, QualityTier: tier.String()}, nil
}

func randID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// looseMatch — нестрогое совпадение имён: после нормализации одно содержит
// другое (учитывает «feat.», разный регистр, диакритику).
func looseMatch(want, got string) bool {
	a := quality.NormalizeKeyPart(want)
	b := quality.NormalizeKeyPart(got)
	if a == "" || b == "" {
		return true
	}
	return strings.Contains(a, b) || strings.Contains(b, a)
}
