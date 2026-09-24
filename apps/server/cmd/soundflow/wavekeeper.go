package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/waveform"
)

// Программа сама досчитывает «рельеф громкости» — реальную форму звука каждой песни по 64
// кусочкам — для полоски-эквалайзера в плеере (Alex TG 24.09.2026: «научи программу это делать,
// чтобы она всё умела делать сама», после того как заметил, что полоска пляшет наугад, а не под
// музыку). Раньше это уже считали для полоски-«волны» (19.09.2026), но когда Alex выбрал точечную
// матрицу вместо неё, досчёт остановили — телефон эти данные не спрашивал (см. комментарий у
// TrackIDsNeedingAnalysis, internal/localdb/write.go). Теперь полоска снова их использует —
// досчёт нужен опять, отдельным, самостоятельным кругом (не трогаем TrackIDsNeedingAnalysis,
// чтобы не вернуть ту же лишнюю работу на каждый старт для всех, кому реально не нужно).
//
// Что делает: при запуске (через пару минут), потом раз в 6 часов и сразу после новых песен —
// берёт все песни без waveform (NULL), считает через ffmpeg (internal/waveform, дёшево — 8 кГц
// моно), пишет. Не смогла посчитать (битый/немой файл) — пишет пустой срез (не NULL), чтобы не
// пытаться снова на каждом круге. Только читает файлы и пишет одно поле в базе — сами
// музыкальные файлы не трогает.
const (
	wfFirstDelay = 2 * time.Minute
	wfEvery      = 6 * time.Hour
	wfKickSettle = 20 * time.Second
	wfWorkers    = 3
	wfBatch      = 1000 // за один проход хвостом; появятся новые — доберём следующим кругом/Kick
)

type waveformKeeper struct {
	s      *Service
	kick   chan struct{}
	cancel context.CancelFunc

	delay     time.Duration // подменяются в тестах
	every     time.Duration
	computeFn func(path string) ([]byte, error) // подменяется в тестах — настоящий ffmpeg не поднимаем
}

func newWaveformKeeper(s *Service) *waveformKeeper {
	return &waveformKeeper{
		s: s, kick: make(chan struct{}, 1), delay: wfFirstDelay, every: wfEvery,
		computeFn: func(path string) ([]byte, error) { return waveform.FromFile(path, waveform.DefaultBars) },
	}
}

func (k *waveformKeeper) Start() {
	ctx, cancel := context.WithCancel(context.Background())
	k.cancel = cancel
	go k.run(ctx)
}

func (k *waveformKeeper) Stop() {
	if k != nil && k.cancel != nil {
		k.cancel()
	}
}

// Kick — в каталоге появились новые песни: досчитать их волну, не дожидаясь круга.
func (k *waveformKeeper) Kick() {
	if k == nil {
		return
	}
	select {
	case k.kick <- struct{}{}:
	default:
	}
}

func (k *waveformKeeper) run(ctx context.Context) {
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
			if !sleepCtx(ctx, wfKickSettle) {
				return
			}
		}
		if err := k.pass(ctx); err != nil && ctx.Err() == nil {
			log.Printf("хранитель волны: %v", err)
		}
	}
}

func (k *waveformKeeper) pass(ctx context.Context) error {
	s := k.s
	if s.db == nil {
		return nil
	}
	cands, err := s.db.TracksNeedingWaveform(wfBatch)
	if err != nil {
		return fmt.Errorf("выборка песен: %w", err)
	}
	if len(cands) == 0 {
		return nil
	}

	var mu sync.Mutex
	var done, empty, failed int
	var wg sync.WaitGroup
	work := make(chan localdb.WaveformCandidate)
	workers := wfWorkers
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
				k.one(c, &mu, &done, &empty, &failed)
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
		msg := fmt.Sprintf("волна для полоски: посчитано %d из %d (пусто/не вышло %d, ошибок чтения %d)",
			done, len(cands), empty, failed)
		log.Print("хранитель " + msg)
		_ = s.db.AddServerLog("info", "", "", msg, 0)
	}
	// в очереди мог остаться хвост (wfBatch) — сразу продолжить, не ждать 6 часов
	if len(cands) == wfBatch && ctx.Err() == nil {
		return k.pass(ctx)
	}
	return nil
}

func (k *waveformKeeper) one(c localdb.WaveformCandidate, mu *sync.Mutex, done, empty, failed *int) {
	s := k.s
	local := s.localPath(c.FilePath)
	if _, err := os.Stat(local); err != nil {
		mu.Lock()
		*failed++
		mu.Unlock()
		return // диск не подключён / файл убрали — не решаем за него, попробуем в другой раз
	}
	wf, err := k.computeFn(local)
	if len(wf) == 0 {
		wf = []byte{} // не NULL — не пытаться снова каждый круг (файл нашёлся, но декодировать
		// нечего/не вышло — тихий, слишком короткий или битый; err уже залогирован ниже)
		mu.Lock()
		if err != nil {
			*failed++
		} else {
			*empty++
		}
		mu.Unlock()
		if err != nil {
			log.Printf("хранитель волны: не смогла посчитать %s: %v", c.ID, err)
		}
	} else {
		mu.Lock()
		*done++
		mu.Unlock()
	}
	if err := s.db.SetWaveform(c.ID, wf); err != nil {
		log.Printf("хранитель волны: не смогла записать %s: %v", c.ID, err)
	}
}
