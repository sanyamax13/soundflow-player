package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/quality"
)

// Программа сама проверяет спектр каждой песни — реальный звук не подделаешь
// заявленным битрейтом («поддельный 320» / фейк-lossless, транскод плохого
// источника под высокий tier). Alex TG 24.09.2026: «научи программу её
// смотреть спектр и прогони по всем песням» — после находки, что треть
// случайной выборки уже помеченных «excellent» треков реально обрезана по
// высоким частотам сильнее, чем должно быть у настоящих 320kbps.
//
// Что делает: при запуске (через пару минут), потом раз в 6 часов и сразу
// после новых песен — берёт все песни без посчитанного spectral_cutoff_hz
// (это же покрывает ВЕСЬ старый каталог — там это поле NULL у всех),
// считает через ffmpeg+FFT (internal/quality.CutoffFromFile), пишет частоту
// среза. Если спектр подозрительно обрезан для заявленного tier — понижает
// tier в track_files на ступень (НЕ удаляет и не отклоняет файл — эвристика,
// возможны ложные срабатывания на тихой мастеринге). Только читает файлы и
// правит два поля в базе — сами музыкальные файлы не трогает.
const (
	scFirstDelay = 3 * time.Minute // позже волны/обложек — тяжелее по CPU (FFT на 44.1кГц)
	scEvery      = 6 * time.Hour
	scKickSettle = 20 * time.Second
	scWorkers    = 3
	scBatch      = 1000
)

type spectrumKeeper struct {
	s      *Service
	kick   chan struct{}
	cancel context.CancelFunc

	delay     time.Duration // подменяются в тестах
	every     time.Duration
	computeFn func(path string) (float64, error) // подменяется в тестах — настоящий ffmpeg не поднимаем
}

func newSpectrumKeeper(s *Service) *spectrumKeeper {
	return &spectrumKeeper{
		s: s, kick: make(chan struct{}, 1), delay: scFirstDelay, every: scEvery,
		computeFn: quality.CutoffFromFile,
	}
}

func (k *spectrumKeeper) Start() {
	ctx, cancel := context.WithCancel(context.Background())
	k.cancel = cancel
	go k.run(ctx)
}

func (k *spectrumKeeper) Stop() {
	if k != nil && k.cancel != nil {
		k.cancel()
	}
}

// Kick — в каталоге появились новые песни: проверить их спектр, не дожидаясь круга.
func (k *spectrumKeeper) Kick() {
	if k == nil {
		return
	}
	select {
	case k.kick <- struct{}{}:
	default:
	}
}

func (k *spectrumKeeper) run(ctx context.Context) {
	first := time.After(k.delay)
	tick := time.NewTicker(k.every)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-first:
			first = nil
		case <-tick.C:
		case <-k.kick:
			if !sleepCtx(ctx, scKickSettle) {
				return
			}
		}
		if err := k.pass(ctx); err != nil && ctx.Err() == nil {
			log.Printf("хранитель спектра: %v", err)
		}
	}
}

func (k *spectrumKeeper) pass(ctx context.Context) error {
	s := k.s
	if s.db == nil {
		return nil
	}
	cands, err := s.db.TracksNeedingSpectrum(scBatch)
	if err != nil {
		return fmt.Errorf("выборка песен: %w", err)
	}
	if len(cands) == 0 {
		return nil
	}

	var mu sync.Mutex
	var done, empty, failed, downgraded int
	var wg sync.WaitGroup
	work := make(chan localdb.SpectrumCandidate)
	workers := scWorkers
	if len(cands) < workers {
		workers = len(cands)
	}
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for c := range work {
				if ctx.Err() != nil {
					continue
				}
				k.one(c, &mu, &done, &empty, &failed, &downgraded)
			}
		}()
	}
feed:
	for _, c := range cands {
		select {
		case work <- c:
		case <-ctx.Done():
			break feed
		}
	}
	close(work)
	wg.Wait()

	if done+empty+failed > 0 {
		msg := fmt.Sprintf("спектр: проверено %d из %d (не определили %d, ошибок чтения %d, понижен tier у %d)",
			done, len(cands), empty, failed, downgraded)
		log.Print("хранитель " + msg)
		_ = s.db.AddServerLog("info", "", "", msg, 0)
	}
	if len(cands) == scBatch && ctx.Err() == nil {
		return k.pass(ctx)
	}
	return nil
}

func (k *spectrumKeeper) one(c localdb.SpectrumCandidate, mu *sync.Mutex, done, empty, failed, downgraded *int) {
	s := k.s
	local := s.localPath(c.FilePath)
	if _, err := os.Stat(local); err != nil {
		mu.Lock()
		*failed++
		mu.Unlock()
		return // диск не подключён / файл убрали — попробуем в другой раз
	}
	cutoff, err := k.computeFn(local)
	if err != nil {
		log.Printf("хранитель спектра: не смогла посчитать %s: %v", c.ID, err)
		cutoff = 0 // пишем 0 (не NULL) и на ошибке декода — иначе битый файл
		// пытались бы пересчитать заново каждые 6 часов до конца времён
		// (тот же урок, что уже ловили на хранителе волны).
	}
	hz := int(cutoff)
	newTier := c.QualityTier
	willDowngrade := false
	if tier := quality.ParseTier(c.QualityTier); quality.SuspiciousCutoff(tier, cutoff) {
		newTier = tier.Downgrade().String()
		willDowngrade = true
	}
	mu.Lock()
	if hz == 0 {
		*empty++
	} else {
		*done++
	}
	if willDowngrade {
		*downgraded++
	}
	mu.Unlock()
	if willDowngrade {
		log.Printf("хранитель спектра: %s — cutoff=%dГц при tier=%s, похоже на транскод, понижаю до %s",
			c.ID, hz, c.QualityTier, newTier)
	}
	if err := s.db.SetSpectralCutoff(c.ID, hz, newTier, willDowngrade); err != nil {
		log.Printf("хранитель спектра: не смогла записать %s: %v", c.ID, err)
	}
}
