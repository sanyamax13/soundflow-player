package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"soundflow/server/internal/appsettings"
	"soundflow/server/internal/localdb"
	"soundflow/server/internal/quality"
	"soundflow/server/internal/sidecar"
	"soundflow/server/internal/tasteseed"
)

// Начальный вкус своей копии плеера (часть 5 передачи плеера, Alex 27–28.09.2026): у нового человека
// нет ни одного лайка, и «Поток», автоподбор и радио не знают, что ему нравится. Если он вошёл в
// Яндекс в мастере первого запуска, программа берёт его «Мне нравится» и песни его плейлистов и
// ставит лайк тем из них, что уже есть в его каталоге; «Не рекомендовать» — в чёрный список.
// Каталог растёт (скан идёт в фоне, качаются новые) — поэтому не разово, а раз в 6 часов и сразу
// после входа; повтор ничего не удваивает (SeedLikes).
//
// Только для входа из мастера (токен в settings.json): у Alex лайки из Яндекса сами не
// подтягиваются — его решение 20.09.2026 (yandex_likes.go).

const (
	seedFirstDelay = 3 * time.Minute
	seedEvery      = 6 * time.Hour
)

type tasteSeeder struct {
	s      *Service
	kick   chan struct{}
	cancel context.CancelFunc
}

func newTasteSeeder(s *Service) *tasteSeeder {
	return &tasteSeeder{s: s, kick: make(chan struct{}, 1)}
}

func (k *tasteSeeder) Start() {
	ctx, cancel := context.WithCancel(context.Background())
	k.cancel = cancel
	go k.run(ctx)
}

func (k *tasteSeeder) Stop() {
	if k != nil && k.cancel != nil {
		k.cancel()
	}
}

// Kick — вошли в Яндекс: собрать вкус сейчас, не дожидаясь круга.
func (k *tasteSeeder) Kick() {
	if k == nil {
		return
	}
	select {
	case k.kick <- struct{}{}:
	default:
	}
}

func (k *tasteSeeder) run(ctx context.Context) {
	wait := seedFirstDelay
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		case <-k.kick:
			time.Sleep(30 * time.Second) // качалке — перезапуститься с новым токеном
		}
		wait = seedEvery
		if st, _ := appsettings.Load(dataDir()); st.YandexToken == "" {
			continue
		}
		if err := k.once(ctx); err != nil {
			log.Printf("SoundFlow: начальный вкус из Яндекса: %v", err)
		}
	}
}

func (k *tasteSeeder) once(ctx context.Context) error {
	base := k.s.sidecarURL()
	if base == "" {
		return nil // качалка ещё не готова — в следующий круг
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	sc := sidecar.New(base)
	liked, err := sc.YandexTasteSeed(ctx)
	if err != nil {
		return err
	}
	names, err := k.s.db.TrackNames()
	if err != nil {
		return err
	}
	pairs := make([]tasteseed.Pair, len(liked))
	for i, it := range liked {
		pairs[i] = tasteseed.Pair{Artist: it.Artist, Title: it.Title}
	}
	ids := tasteseed.Match(names, pairs)
	added, err := k.s.db.SeedLikes(ids, "yandex")
	if err != nil {
		return err
	}
	blocked := 0
	if dis, err := sc.YandexDislikes(ctx); err == nil {
		marks := make([]localdb.BlockedMark, 0, len(dis))
		for _, it := range dis {
			if it.Artist != "" || it.Title != "" {
				marks = append(marks, localdb.BlockedMark{
					NormalizedKey: quality.NormalizedKey(it.Artist, it.Title), Artist: it.Artist, Title: it.Title})
			}
		}
		blocked, _ = k.s.db.ImportBlocked(marks)
	}
	if added > 0 || blocked > 0 {
		_ = k.s.db.AddServerLog("info", "", "", fmt.Sprintf("вкус из Яндекса: лайков %d, в чёрный список %d", added, blocked), 0)
		go func() {
			_, _, _ = k.s.db.RecomputeTasteClusters("long_term", nil)
		}()
	}
	return nil
}
