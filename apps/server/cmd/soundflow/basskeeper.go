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

// Программа сама разбирает удары баса каждой песни (27.09.2026, Alex: «от кнопки плей пульсация под
// басы», «давай делай»): 20 отметок в секунду по низким частотам (internal/waveform/bass.go),
// телефон по ним вспыхивает кнопкой «играть» в такт. Устроено как хранитель волны (wavekeeper.go):
// при запуске (через 8 минут — позже остальных, чтобы не мешать), раз в 6 часов и сразу после
// новых песен берёт песни без bass_env, считает через ffmpeg, пишет. Не вышло — пустой срез, чтобы
// не пытаться снова. Только читает файлы и пишет одно поле в базе.

const (
	bsFirstDelay = 8 * time.Minute
	bsEvery      = 6 * time.Hour
	bsKickSettle = 20 * time.Second
	bsWorkers    = 2
	bsBatch      = 1000 // за один проход хвостом; появятся новые — доберём следующим кругом/Kick
)

type bassKeeper struct {
	s      *Service
	kick   chan struct{}
	cancel context.CancelFunc

	delay     time.Duration // подменяются в тестах
	every     time.Duration
	computeFn func(path string) ([]byte, error) // подменяется в тестах — настоящий ffmpeg не поднимаем
}

func newBassKeeper(s *Service) *bassKeeper {
	return &bassKeeper{
		s: s, kick: make(chan struct{}, 1), delay: bsFirstDelay, every: bsEvery,
		computeFn: func(path string) ([]byte, error) { return waveform.BassFromFile(path) },
	}
}

func (k *bassKeeper) Start() {
	ctx, cancel := context.WithCancel(context.Background())
	k.cancel = cancel
	go k.run(ctx)
}

func (k *bassKeeper) Stop() {
	if k != nil && k.cancel != nil {
		k.cancel()
	}
}

// Kick — в каталоге появились новые песни: разобрать их бас, не дожидаясь круга.
func (k *bassKeeper) Kick() {
	if k == nil {
		return
	}
	select {
	case k.kick <- struct{}{}:
	default:
	}
}

func (k *bassKeeper) run(ctx context.Context) {
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
			if !sleepCtx(ctx, bsKickSettle) {
				return
			}
		}
		if err := k.pass(ctx); err != nil && ctx.Err() == nil {
			log.Printf("хранитель баса: %v", err)
		}
	}
}

func (k *bassKeeper) pass(ctx context.Context) error {
	s := k.s
	if s.db == nil {
		return nil
	}
	cands, err := s.db.TracksNeedingBass(bsBatch)
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
	workers := bsWorkers
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
		msg := fmt.Sprintf("удары баса: посчитано %d из %d (пусто/не вышло %d, ошибок чтения %d)",
			done, len(cands), empty, failed)
		log.Print("хранитель " + msg)
		_ = s.db.AddServerLog("info", "", "", msg, 0)
	}
	// в очереди мог остаться хвост (bsBatch) — сразу продолжить, не ждать 6 часов
	// Продолжаем хвостом, только если в этом круге что-то записали: иначе (диск с музыкой не
	// подключён — файлы «не нашлись», в базе остаются NULL) те же bsBatch песен вернулись бы снова
	// и круг крутился бы без конца (ревизия кода 27.09.2026).
	if len(cands) == bsBatch && done+empty > 0 && ctx.Err() == nil {
		return k.pass(ctx)
	}
	return nil
}

func (k *bassKeeper) one(c localdb.WaveformCandidate, mu *sync.Mutex, done, empty, failed *int) {
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
			log.Printf("хранитель баса: не смогла посчитать %s: %v", c.ID, err)
		}
	} else {
		mu.Lock()
		*done++
		mu.Unlock()
	}
	if err := s.db.SetBass(c.ID, wf); err != nil {
		log.Printf("хранитель баса: не смогла записать %s: %v", c.ID, err)
	}
}
