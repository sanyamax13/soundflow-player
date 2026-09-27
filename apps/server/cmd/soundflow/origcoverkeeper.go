package main

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"soundflow/server/internal/coverart"
	"soundflow/server/internal/coverfind"
	"soundflow/server/internal/localdb"
)

// Программа сама ищет РОДНУЮ обложку песням из сборников (26.09.2026, Alex TG 21750: «к каждой
// песне найди обложку оригинальную или фанатскую; если в сборниках нет оригинальной — бери
// основную из сборника»). У песни со сборника в файле зашита картинка сборника («Хиты 2020»);
// здесь ищем обложку её собственного альбома/сингла теми же источниками, что и обычные обложки
// (coverfind: Яндекс — альбом самого исполнителя, не сборник; Deezer, iTunes…). Нашла — кладёт в
// original_covers/<id>.jpg рядом с базой, сервер отдаёт её раньше зашитой. Не нашла — остаётся
// обложка сборника, повтор через 30 дней. Музыкальные файлы не трогает.
const (
	origCoverFirstDelay = 5 * time.Minute
	origCoverEvery      = 6 * time.Hour
	origCoverKickSettle = 40 * time.Second
	origCoverRetryDays  = 30
	origCoverWorkers    = 3
)

type origCoverKeeper struct {
	s      *Service
	kick   chan struct{}
	cancel context.CancelFunc

	newFinder func() *coverfind.Finder // подменяется в тестах
	delay     time.Duration
	every     time.Duration
	settle    time.Duration
}

func newOrigCoverKeeper(s *Service) *origCoverKeeper {
	k := &origCoverKeeper{
		s:      s,
		kick:   make(chan struct{}, 1),
		delay:  origCoverFirstDelay,
		every:  origCoverEvery,
		settle: origCoverKickSettle,
	}
	k.newFinder = func() *coverfind.Finder { return s.covers.defaultFinder() }
	return k
}

func (s *Service) originalCoversDir() string {
	return filepath.Join(filepath.Dir(s.dbPath), "original_covers")
}

func (k *origCoverKeeper) Start() {
	ctx, cancel := context.WithCancel(context.Background())
	k.cancel = cancel
	go k.run(ctx)
}

func (k *origCoverKeeper) Stop() {
	if k != nil && k.cancel != nil {
		k.cancel()
	}
}

func (k *origCoverKeeper) Kick() {
	if k == nil {
		return
	}
	select {
	case k.kick <- struct{}{}:
	default:
	}
}

func (k *origCoverKeeper) run(ctx context.Context) {
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
			log.Printf("хранитель родных обложек: %v", err)
		}
	}
}

func (k *origCoverKeeper) pass(ctx context.Context) error {
	s := k.s
	if s.db == nil {
		return nil
	}
	if s.covers != nil && !s.covers.sidecarReady() {
		return errSidecarStarting // без Яндекса родной альбом не отличить от сборника — ждём качалку
	}
	retryBefore := time.Now().AddDate(0, 0, -origCoverRetryDays).Format("2006-01-02")
	cands, err := s.db.TracksNeedingOriginalCover(retryBefore, 1_000_000)
	if err != nil {
		return fmt.Errorf("выборка песен: %w", err)
	}
	if len(cands) == 0 {
		return nil
	}
	// Только тем, у кого в файле действительно картинка СБОРНИКА: одна и та же у нескольких
	// разных исполнителей этой папки. Своя уникальная обложка (сингл «BTS — Film Out» внутри
	// сборника) — родная уже, не трогаем (урок 26.09.2026: первая версия заменила её хуже).
	cands = k.onlyCompilationCovers(cands)
	if len(cands) == 0 {
		return nil
	}
	finder := k.newFinder()
	if finder == nil || len(finder.Sources) == 0 {
		return nil
	}
	dir := s.originalCoversDir()
	var found, none, failed, offline atomic.Int64
	jobs := make(chan localdb.OrigCoverCandidate)
	var wg sync.WaitGroup
	cctx, stop := context.WithCancel(ctx)
	defer stop()
	for w := 0; w < origCoverWorkers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for c := range jobs {
				res, err := finder.Find(cctx, c.Artist, c.Title)
				switch {
				case errors.Is(err, coverfind.ErrOffline):
					if offline.Add(1) >= coverOfflineStop {
						stop()
					}
					continue
				case err != nil:
					continue // отмена круга
				}
				offline.Store(0)
				if res == nil {
					none.Add(1)
					_ = s.db.SetOriginalCover(c.ID, false)
					continue
				}
				if err := writeFoundCover(dir, c.ID, res.JPEG); err != nil {
					failed.Add(1)
					log.Printf("хранитель родных обложек: запись %s: %v", c.ID, err)
					continue
				}
				found.Add(1)
				_ = s.db.SetOriginalCover(c.ID, true)
			}
		}()
	}
feed:
	for _, c := range cands {
		select {
		case jobs <- c:
		case <-cctx.Done():
			break feed
		}
	}
	close(jobs)
	wg.Wait()
	msg := fmt.Sprintf("Родные обложки для песен из сборников: нашла %d, не нашла %d (остаётся обложка сборника), не записала %d (из %d)",
		found.Load(), none.Load(), failed.Load(), len(cands))
	log.Print("хранитель " + msg)
	_ = s.db.AddServerLog("info", "", "", msg, 0)
	return nil
}

// onlyCompilationCovers — отсеять песни со своей обложкой (пометить 'own'). Обложка считается
// обложкой сборника, если такая же картинка (по содержимому) зашита у 3+ песен папки от 2+ разных
// исполнителей, или если зашитой нет, а есть картинка папки (у сборника она общая).
func (k *origCoverKeeper) onlyCompilationCovers(cands []localdb.OrigCoverCandidate) []localdb.OrigCoverCandidate {
	type info struct {
		hash   string
		artist string
	}
	byDir := map[string][]int{}
	infos := make([]info, len(cands))
	for i, c := range cands {
		local := k.s.covers.localFile(c.FilePath)
		if data, _, ok := coverart.Embedded(local); ok {
			sum := sha1.Sum(data)
			infos[i] = info{hash: hex.EncodeToString(sum[:]), artist: strings.ToLower(c.Artist)}
		} else if _, ok := coverart.FolderImage(local); ok {
			infos[i] = info{hash: "folder", artist: strings.ToLower(c.Artist)}
		}
		byDir[c.Dir] = append(byDir[c.Dir], i)
	}
	var out []localdb.OrigCoverCandidate
	for dir, idx := range byDir {
		count := map[string]int{}
		artists := map[string]map[string]bool{}
		add := func(h, artist string) {
			if h == "" {
				return
			}
			count[h]++
			if artists[h] == nil {
				artists[h] = map[string]bool{}
			}
			artists[h][artist] = true
		}
		// Считаем по ВСЕЙ папке, не только по кандидатам этого прохода (ревизия кода 27.09.2026).
		mine := map[string]bool{}
		for _, i := range idx {
			mine[cands[i].ID] = true
			add(infos[i].hash, infos[i].artist)
		}
		if sibs, err := k.s.db.DirSiblings(dir); err == nil {
			for _, sb := range sibs {
				if mine[sb.ID] {
					continue
				}
				if data, _, ok := coverart.Embedded(k.s.covers.localFile(sb.FilePath)); ok {
					sum := sha1.Sum(data)
					add(hex.EncodeToString(sum[:]), strings.ToLower(sb.Artist))
				}
			}
		}
		for _, i := range idx {
			h := infos[i].hash
			switch {
			case h == "": // обложки нет вовсе — это забота обычного хранителя обложек
			case h == "folder" || (count[h] >= 3 && len(artists[h]) >= 2):
				out = append(out, cands[i])
			default:
				_ = k.s.db.SetOriginalCoverState(cands[i].ID, "own")
			}
		}
	}
	return out
}
