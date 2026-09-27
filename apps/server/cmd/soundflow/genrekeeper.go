package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"soundflow/server/internal/sidecar"
)

// Программа сама узнаёт жанр каждой песни (26.09.2026, план Alex «по твоему плану», шаг 4: жанра
// не было ни у одной из 11 632 песен; без него нельзя фильтровать радио по жанру). По образцу
// хранителя обложек (coverkeeper.go):
//   - через пару минут после запуска, потом раз в 6 часов и сразу после новых песен берёт все песни,
//     у которых жанр ещё не спрашивали, и спрашивает Яндекс через качалку (/yandex/track-genre, та же
//     проверка «тот ли трек», что при скачивании);
//   - нашёл — пишет код жанра (rusrap, pop…) в tracks.genre_tags; Яндекс не знает — метку «-», больше
//     не спрашивает; спросить не получилось (нет сети) — не трогает, спросит в следующий круг.
// Музыкальные файлы не трогает, только базу.
const (
	genreFirstDelay  = 3 * time.Minute
	genreEvery       = 6 * time.Hour
	genreKickSettle  = 30 * time.Second
	genreWorkers     = 3
	genreOfflineStop = 10 // столько ошибок подряд — Яндекс/сеть недоступны, круг прерываем
)

type genreKeeper struct {
	s      *Service
	kick   chan struct{}
	cancel context.CancelFunc

	// подменяются в тестах
	ask    func(ctx context.Context, artist, title string) (string, error)
	delay  time.Duration
	every  time.Duration
	settle time.Duration
}

func newGenreKeeper(s *Service) *genreKeeper {
	return &genreKeeper{
		s:      s,
		kick:   make(chan struct{}, 1),
		delay:  genreFirstDelay,
		every:  genreEvery,
		settle: genreKickSettle,
	}
}

func (k *genreKeeper) Start() {
	ctx, cancel := context.WithCancel(context.Background())
	k.cancel = cancel
	go k.run(ctx)
}

func (k *genreKeeper) Stop() {
	if k != nil && k.cancel != nil {
		k.cancel()
	}
}

// Kick — появились новые песни: узнать их жанр, не дожидаясь круга. Можно на nil.
func (k *genreKeeper) Kick() {
	if k == nil {
		return
	}
	select {
	case k.kick <- struct{}{}:
	default:
	}
}

func (k *genreKeeper) run(ctx context.Context) {
	first := time.After(k.delay)
	tick := time.NewTicker(k.every)
	defer tick.Stop()
	var retry <-chan time.Time
	for {
		select {
		case <-ctx.Done():
			return
		case <-first:
			first = nil
		case <-retry:
			retry = nil
		case <-tick.C:
		case <-k.kick:
			if !sleepCtx(ctx, k.settle) {
				return
			}
		}
		err := k.pass(ctx)
		switch {
		case errors.Is(err, errSidecarStarting):
			retry = time.After(time.Minute)
		case err != nil && ctx.Err() == nil:
			log.Printf("хранитель жанров: %v", err)
		}
	}
}

// asker — чем спрашивать жанр: подменённое в тесте или настоящая качалка (пока не поднялась —
// errSidecarStarting, повторим через минуту).
func (k *genreKeeper) asker() (func(ctx context.Context, artist, title string) (string, error), error) {
	if k.ask != nil {
		return k.ask, nil
	}
	u := k.s.sidecarURL()
	if u == "" {
		if ready, permanent, _ := k.s.downloaderState(); !ready && !permanent {
			return nil, errSidecarStarting
		}
		return nil, nil // качалки нет совсем — жанры узнавать нечем
	}
	return sidecar.New(u).YandexTrackGenre, nil
}

func (k *genreKeeper) pass(ctx context.Context) error {
	s := k.s
	if s.db == nil {
		return nil
	}
	ask, err := k.asker()
	if err != nil || ask == nil {
		return err
	}
	cands, err := s.db.TracksNeedingGenre(1_000_000)
	if err != nil {
		return fmt.Errorf("выборка песен: %w", err)
	}
	if len(cands) == 0 {
		return nil
	}
	var found, unknown, failed atomic.Int64
	var streak atomic.Int64
	jobs := make(chan int)
	var wg sync.WaitGroup
	cctx, stop := context.WithCancel(ctx)
	defer stop()
	for w := 0; w < genreWorkers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				c := cands[i]
				g, err := ask(cctx, c.Artist, c.Title)
				if err != nil {
					failed.Add(1)
					if streak.Add(1) >= genreOfflineStop {
						stop()
					}
					continue
				}
				streak.Store(0)
				if g == "" {
					unknown.Add(1)
				} else {
					found.Add(1)
				}
				if err := s.db.SetGenre(c.ID, g); err != nil {
					log.Printf("хранитель жанров: запись %s: %v", c.ID, err)
				}
			}
		}()
	}
feed:
	for i := range cands {
		select {
		case jobs <- i:
		case <-cctx.Done():
			break feed
		}
	}
	close(jobs)
	wg.Wait()
	msg := fmt.Sprintf("Жанры: узнал %d, Яндекс не знает %d, не спросилось %d (из %d)",
		found.Load(), unknown.Load(), failed.Load(), len(cands))
	log.Print("хранитель жанров: " + msg)
	_ = s.db.AddServerLog("info", "", "", msg, 0)
	return nil
}
