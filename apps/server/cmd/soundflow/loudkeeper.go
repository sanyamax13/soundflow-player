package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"sync"
	"time"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/proc"
)

// Программа сама считает громкость каждой песни (EBU R128, LUFS) — для выравнивания громкости на
// телефоне (26.09.2026, общий вывод пяти разборов SoundFlow: в машине скачки громкости между
// сборниками — самое заметное неудобство). Как хранитель волны: через пару минут после запуска,
// потом раз в 6 часов и сразу после новых песен; ffmpeg только читает файл — музыку не трогает,
// в базе пишется одно число.
const (
	ldFirstDelay = 4 * time.Minute
	ldEvery      = 6 * time.Hour
	ldKickSettle = 25 * time.Second
	ldWorkers    = 3
	ldBatch      = 1000
)

type loudKeeper struct {
	s      *Service
	kick   chan struct{}
	cancel context.CancelFunc

	delay     time.Duration // подменяются в тестах
	every     time.Duration
	measureFn func(path string) (float64, error) // подменяется в тестах — настоящий ffmpeg не поднимаем
}

func newLoudKeeper(s *Service) *loudKeeper {
	return &loudKeeper{
		s: s, kick: make(chan struct{}, 1), delay: ldFirstDelay, every: ldEvery,
		measureFn: measureLUFS,
	}
}

func (k *loudKeeper) Start() {
	ctx, cancel := context.WithCancel(context.Background())
	k.cancel = cancel
	go k.run(ctx)
}

func (k *loudKeeper) Stop() {
	if k != nil && k.cancel != nil {
		k.cancel()
	}
}

// Kick — в каталоге появились новые песни: досчитать их громкость, не дожидаясь круга.
func (k *loudKeeper) Kick() {
	if k == nil {
		return
	}
	select {
	case k.kick <- struct{}{}:
	default:
	}
}

func (k *loudKeeper) run(ctx context.Context) {
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
			if !sleepCtx(ctx, ldKickSettle) {
				return
			}
		}
		if err := k.pass(ctx); err != nil && ctx.Err() == nil {
			log.Printf("хранитель громкости: %v", err)
		}
	}
}

func (k *loudKeeper) pass(ctx context.Context) error {
	s := k.s
	if s.db == nil {
		return nil
	}
	cands, err := s.db.TracksNeedingLoudness(ldBatch)
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
	workers := ldWorkers
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
		msg := fmt.Sprintf("громкость песен: посчитано %d из %d (не вышло %d, файлов не нашлось %d)",
			done, len(cands), empty, failed)
		log.Print("хранитель " + msg)
		_ = s.db.AddServerLog("info", "", "", msg, 0)
	}
	// в очереди мог остаться хвост (ldBatch) — сразу продолжить, не ждать 6 часов
	// Продолжаем хвостом, только если в этом круге что-то записали: иначе (диск с музыкой не
	// подключён — файлы «не нашлись», в базе остаются NULL) те же ldBatch песен вернулись бы снова
	// и круг крутился бы без конца (ревизия кода 27.09.2026).
	if len(cands) == ldBatch && done+empty > 0 && ctx.Err() == nil {
		return k.pass(ctx)
	}
	return nil
}

func (k *loudKeeper) one(c localdb.WaveformCandidate, mu *sync.Mutex, done, empty, failed *int) {
	s := k.s
	local := s.localPath(c.FilePath)
	if _, err := os.Stat(local); err != nil {
		mu.Lock()
		*failed++
		mu.Unlock()
		return // файла нет на месте — не решаем за него, попробуем в другой раз
	}
	lufs, err := k.measureFn(local)
	if err != nil || lufs < -70 || lufs > 5 {
		// не вышло / тишина — метка «не известна», чтобы не пытаться каждый круг
		mu.Lock()
		*empty++
		mu.Unlock()
		if err != nil {
			log.Printf("хранитель громкости: не смогла посчитать %s: %v", c.ID, err)
		}
		lufs = localdb.LoudnessUnknown
	} else {
		mu.Lock()
		*done++
		mu.Unlock()
	}
	if err := s.db.SetLoudness(c.ID, lufs); err != nil {
		log.Printf("хранитель громкости: не смогла записать %s: %v", c.ID, err)
	}
}

var lufsRe = regexp.MustCompile(`(?m)^\s*I:\s*(-?[0-9.]+)\s*LUFS`)

// measureLUFS — интегральная громкость файла (EBU R128) через ffmpeg: полсекунды на песню.
func measureLUFS(path string) (float64, error) {
	cmd := proc.Quiet(exec.Command(proc.FFmpeg(), "-hide_banner", "-nostats", "-vn", "-sn", "-dn",
		"-i", path, "-af", "ebur128=framelog=quiet", "-f", "null", "-"))
	out, err := cmd.CombinedOutput()
	m := lufsRe.FindAllSubmatch(out, -1)
	if len(m) == 0 {
		if err == nil {
			err = fmt.Errorf("ffmpeg не сообщил громкость")
		}
		return 0, err
	}
	return strconv.ParseFloat(string(m[len(m)-1][1]), 64)
}
