package acquire

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"soundflow/server/internal/db"
	"soundflow/server/internal/quality"
	"soundflow/server/internal/sidecar"
)

type fakeFinder struct {
	res              sidecar.FindAudioResult
	err              error
	id3Artist, id3Ti string
}

func (f fakeFinder) FindAudio(_ context.Context, _, _ string, _ int, _ []string) (sidecar.FindAudioResult, error) {
	return f.res, f.err
}
func (f fakeFinder) ID3Info(_ context.Context, _ string) (string, string, error) {
	return f.id3Artist, f.id3Ti, nil
}
func (f fakeFinder) YandexTrackCover(_ context.Context, _, _ string) (string, error) {
	return "https://cover/600", nil
}

func testDB(t *testing.T) *db.Pool {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		url = "postgres://soundflow:soundflow_dev@localhost:5433/soundflow?sslmode=disable"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	p, err := db.Open(ctx, url)
	if err != nil {
		t.Skipf("нет базы (%v)", err)
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		t.Skipf("база молчит (%v)", err)
	}
	if err := p.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(p.Close)
	return p
}

func TestAcquireRejectsLiveByTitle(t *testing.T) {
	s := &Service{Finder: fakeFinder{}}
	_, err := s.Acquire(context.Background(), Request{Artist: "Кино", Title: "Группа крови (Live at Wembley)"})
	if !errors.Is(err, ErrRejected) {
		t.Fatalf("ждал ErrRejected, получил %v", err)
	}
}

func TestAcquireHappyPathAndDedup(t *testing.T) {
	p := testDB(t)
	ctx := context.Background()
	artist := "AcqTest " + randID()
	title := "Song"
	key := quality.NormalizedKey(artist, title)
	t.Cleanup(func() { _ = p.DeleteTrackByKey(context.Background(), key) })

	s := &Service{DB: p, Finder: fakeFinder{res: sidecar.FindAudioResult{
		Found: true, FilePath: `E:\soundflow-data\cache\x.mp3`, BitrateKbps: 320,
		DurationSec: 200, SizeBytes: 8_000_000, Source: "yandex", ProviderURL: "yandexmusic://1",
	}}}

	r1, err := s.Acquire(ctx, Request{Artist: artist, Title: title, ExpectedDurationSec: 205})
	if err != nil {
		t.Fatalf("Acquire #1: %v", err)
	}
	if !r1.Created || r1.Source != "yandex" || r1.QualityTier != "excellent" {
		t.Fatalf("неверный результат: %+v", r1)
	}

	r2, err := s.Acquire(ctx, Request{Artist: artist, Title: title})
	if err != nil {
		t.Fatalf("Acquire #2: %v", err)
	}
	if r2.Created || r2.TrackID != r1.TrackID {
		t.Fatalf("дубль: ждал существующий %s, получил %+v", r1.TrackID, r2)
	}

	path, ok, err := p.TrackFilePath(ctx, r1.TrackID)
	if err != nil || !ok || path != `E:\soundflow-data\cache\x.mp3` {
		t.Fatalf("TrackFilePath: %q %v %v", path, ok, err)
	}
}

func TestAcquireLowQualityRejected(t *testing.T) {
	p := testDB(t)
	ctx := context.Background()
	artist := "LowQ " + randID()
	key := quality.NormalizedKey(artist, "Track")
	t.Cleanup(func() { _ = p.DeleteTrackByKey(context.Background(), key) })

	s := &Service{DB: p, Finder: fakeFinder{res: sidecar.FindAudioResult{
		Found: true, FilePath: `E:\soundflow-data\cache\y.mp3`, BitrateKbps: 96, Source: "musify",
	}}}
	_, err := s.Acquire(ctx, Request{Artist: artist, Title: "Track"})
	if !errors.Is(err, ErrLowQuality) {
		t.Fatalf("ждал ErrLowQuality, получил %v", err)
	}
	if tk, _ := p.TrackByKey(ctx, key); tk != nil {
		t.Error("трек не должен был вставиться")
	}
}

func TestAcquireNotFound(t *testing.T) {
	p := testDB(t)
	s := &Service{DB: p, Finder: fakeFinder{res: sidecar.FindAudioResult{Found: false}}}
	_, err := s.Acquire(context.Background(), Request{Artist: "Nobody " + randID(), Title: "Nothing"})
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("ждал ErrNotFound, получил %v", err)
	}
}

func TestAcquireWrongTrackByID3(t *testing.T) {
	p := testDB(t)
	ctx := context.Background()
	artist := "Кино " + randID()
	key := quality.NormalizedKey(artist, "Звезда по имени Солнце")
	t.Cleanup(func() { _ = p.DeleteTrackByKey(context.Background(), key) })

	// торрент отдал файл с тегами чужого альбома
	s := &Service{DB: p, Finder: fakeFinder{
		res:       sidecar.FindAudioResult{Found: true, FilePath: `E:\soundflow-data\music\Bahyt\03.mp3`, BitrateKbps: 320, DurationSec: 252, Source: "nnmclub_album"},
		id3Artist: "Бахыт Компот",
		id3Ti:     "На высокой круглешине танцы",
	}}
	_, err := s.Acquire(ctx, Request{Artist: artist, Title: "Звезда по имени Солнце"})
	if !errors.Is(err, ErrWrongTrack) {
		t.Fatalf("ждал ErrWrongTrack, получил %v", err)
	}
	if tk, _ := p.TrackByKey(ctx, key); tk != nil {
		t.Error("чужой трек не должен был попасть в каталог")
	}
}

func TestAcquireID3MatchOK(t *testing.T) {
	p := testDB(t)
	ctx := context.Background()
	artist := "Кино " + randID()
	key := quality.NormalizedKey(artist, "Группа крови")
	t.Cleanup(func() { _ = p.DeleteTrackByKey(context.Background(), key) })

	// теги совпадают (с «feat.» и другим регистром) — пропускаем
	s := &Service{DB: p, Finder: fakeFinder{
		res:       sidecar.FindAudioResult{Found: true, FilePath: `E:\soundflow-data\cache\k.mp3`, BitrateKbps: 320, DurationSec: 285, Source: "yandex"},
		id3Artist: strings.ToUpper(artist),
		id3Ti:     "Группа крови (feat. никто)",
	}}
	r, err := s.Acquire(ctx, Request{Artist: artist, Title: "Группа крови"})
	if err != nil || !r.Created {
		t.Fatalf("ждал успех, получил %+v %v", r, err)
	}
}
