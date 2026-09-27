package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"soundflow/server/internal/coverart"
	"soundflow/server/internal/coverfind"
	"soundflow/server/internal/localdb"
	"soundflow/server/internal/sidecar"
	"soundflow/server/internal/tagfix"
)

// Программа сама следит, чтобы у каждой песни была обложка (Alex TG 20152: «найди обложки для
// каждой песни»; TG 20159: «если новая песня появляется без обложки, пусть сама ищет обложки —
// не ты должен делать, а сама программа»).
//
// Что делает:
//   - при запуске (через пару минут, когда качалка успела подняться), потом раз в 6 часов и
//     сразу после того, как в каталоге появились новые песни (скан папки, скачивание), берёт
//     все песни, у которых обложку ещё не проверяли;
//   - если обложка уже есть — вшита в файл, лежит картинкой в папке альбома или уже найдена
//     раньше, — просто ставит метку в tracks.cover_url, чтобы больше не смотреть (метки — в
//     internal/localdb/covers.go);
//   - иначе ищет в интернете (Яндекс, Deezer, iTunes, AudioDB, MusicBrainz) с проверкой «тот ли
//     исполнитель и трек» (internal/coverfind), кладёт найденную картинку в found_covers/<id>.jpg
//     (рядом с базой) и ставит метку 'found';
//   - не нашла — метка 'none@ГГГГ-ММ-ДД', повторный поиск не раньше чем через неделю.
//
// Сами музыкальные файлы НЕ трогает: пишет только метку в базе и картинки в свою папку
// found_covers. Нет интернета (ни один источник не ответил) — ничего не помечает, ждёт
// следующего круга.
const (
	coverFirstDelay  = 2 * time.Minute
	coverEvery       = 6 * time.Hour
	coverKickSettle  = 20 * time.Second // после пачки добавлений даём ей закончиться
	coverRetryDays   = 7
	coverWorkers     = 3
	coverOfflineStop = 8                // столько подряд «ни один источник не ответил» — круг прерываем
	coverSidecarWait = 15 * time.Minute // качалка не поднялась за это время после старта — ищем без Яндекса
)

var errSidecarStarting = errors.New("качалка ещё запускается")

type coverKeeper struct {
	s      *Service
	kick   chan struct{}
	cancel context.CancelFunc

	// подменяются в тестах
	newFinder func() *coverfind.Finder
	now       func() time.Time
	delay     time.Duration
	every     time.Duration
	settle    time.Duration
}

func newCoverKeeper(s *Service) *coverKeeper {
	k := &coverKeeper{
		s:      s,
		kick:   make(chan struct{}, 1),
		now:    time.Now,
		delay:  coverFirstDelay,
		every:  coverEvery,
		settle: coverKickSettle,
	}
	k.newFinder = k.defaultFinder
	return k
}

// Start — запустить фоновый цикл. Останавливается Stop() (при закрытии программы).
func (k *coverKeeper) Start() {
	ctx, cancel := context.WithCancel(context.Background())
	k.cancel = cancel
	go k.run(ctx)
}

func (k *coverKeeper) Stop() {
	if k != nil && k.cancel != nil {
		k.cancel()
	}
}

// Kick — в каталоге появились новые песни: проверить их обложки, не дожидаясь круга. Можно
// вызывать на nil (тесты без хранителя) и сколько угодно раз подряд — лишние сливаются в один.
func (k *coverKeeper) Kick() {
	if k == nil {
		return
	}
	select {
	case k.kick <- struct{}{}:
	default:
	}
}

func (k *coverKeeper) run(ctx context.Context) {
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
			log.Printf("хранитель обложек: %v", err)
		}
	}
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

// defaultFinder — настоящие источники; Яндекс — только когда качалка отвечает.
func (k *coverKeeper) defaultFinder() *coverfind.Finder {
	var yandex func(ctx context.Context, artist, title string) ([]coverfind.Candidate, error)
	if u := k.s.sidecarURL(); u != "" {
		yandex = coverfind.YandexSource(sidecar.New(u).YandexTrackCandidates)
	}
	w := coverfind.NewWeb()
	return &coverfind.Finder{Sources: w.Sources(yandex), ArtistSources: w.ArtistSources()}
}

// sidecarReady — можно ли уже искать. Качалку программа поднимает сама, и без неё Яндекс не
// работает (а он лучше всех знает русскую музыку) — поэтому пока она стартует, ждём; но не
// вечно: не поднялась за coverSidecarWait — ищем без неё.
func (k *coverKeeper) sidecarReady() bool {
	s := k.s
	if ready, permanent, _ := s.downloaderState(); ready || permanent {
		return true
	}
	return time.Since(s.startedAt) > coverSidecarWait
}

// localFile — путь файла песни на этой машине (тем же способом, каким обложку потом отдают
// телефону и окну).
func (k *coverKeeper) localFile(canon string) string {
	s := k.s
	if len(s.pm.LocalRoots()) > 0 {
		return s.pm.ToLocal(canon)
	}
	return s.localPath(canon)
}

func (k *coverKeeper) mark(id, marker string) {
	if err := k.s.db.SetCoverMarker(id, marker); err != nil {
		log.Printf("хранитель обложек: метка %s для %s: %v", marker, id, err)
	}
}

// coverPassStats — итог круга для журнала.
type coverPassStats struct {
	embedded, folder, already int // обложка уже была: в файле / в папке / найдена раньше
	fetched, none             int // поиск: нашла / не нашла
	artist                    int // обложки песни нет — взяла фото исполнителя
	failed, offline           int // не смогла записать файл / ни один источник не ответил
}

func (k *coverKeeper) pass(ctx context.Context) error {
	s := k.s
	if s.db == nil {
		return nil
	}
	if !k.sidecarReady() {
		return errSidecarStarting
	}
	// Имена исполнителей — сперва почистить (27.09.2026, Alex: «гр это группа, виа тоже лишнее»):
	// «Гр. «Отпетые мошенники»» → «Отпетые мошенники». Новые песни попадают сюда же — круг
	// запускается после каждого добавления в каталог.
	if n, err := s.db.CleanArtistNames(tagfix.CleanArtist); err != nil {
		log.Printf("хранитель обложек: чистка имён: %v", err)
	} else if n > 0 {
		msg := fmt.Sprintf("имена исполнителей: почищено у %d песен (убрала «Гр.», кавычки, лишние пробелы)", n)
		log.Print("хранитель " + msg)
		_ = s.db.AddServerLog("info", "", "", msg, 0)
	}
	// Поиск стал умнее (27.09.2026: чистка «Гр.», «ВИА», инициалов и «(Ремикс …)», фото исполнителя) —
	// один раз переспрашиваем все прежние «не нашла», не дожидаясь недели.
	if v, _, _ := s.db.GetSetting("cover_search_v2"); v == "" {
		if n, err := s.db.ResetCoverMisses(); err == nil {
			_ = s.db.SetSetting("cover_search_v2", "done")
			if n > 0 {
				log.Printf("хранитель обложек: поиск обновился — переспрошу %d песен без обложки", n)
			}
		}
	}
	retryBefore := k.now().AddDate(0, 0, -coverRetryDays).Format("2006-01-02")
	cands, err := s.db.TracksNeedingCoverCheck(retryBefore, 1_000_000)
	if err != nil {
		return fmt.Errorf("выборка песен: %w", err)
	}
	if len(cands) == 0 {
		return nil
	}

	// 1) Быстрое: у кого обложка уже есть на диске — только метка.
	var st coverPassStats
	dir := s.foundCoversDir()
	var need []localdb.CoverCandidate
	for _, c := range cands {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		local := k.localFile(c.FilePath)
		if _, err := os.Stat(local); err != nil {
			continue // диск не подключён / файл убрали — за него не решаем, метку не ставим
		}
		switch {
		case hasEmbeddedCover(local):
			k.mark(c.ID, "embedded")
			st.embedded++
		case hasFolderCover(local):
			k.mark(c.ID, "folder")
			st.folder++
		case hasFoundCover(dir, c.ID):
			k.mark(c.ID, "found")
			st.already++
		default:
			need = append(need, c)
		}
	}

	// 2) Поиск в интернете — только для тех, у кого обложки нигде нет.
	if len(need) > 0 {
		k.search(ctx, need, dir, &st)
	}

	if st.embedded+st.folder+st.already+st.fetched+st.artist+st.none+st.failed+st.offline > 0 {
		msg := fmt.Sprintf("обложки: проверено %d — уже были %d (в файле %d, в папке %d, найдены раньше %d), нашла в интернете %d, фото исполнителя %d, не нашла %d",
			len(cands), st.embedded+st.folder+st.already, st.embedded, st.folder, st.already, st.fetched, st.artist, st.none)
		if st.failed > 0 {
			msg += fmt.Sprintf(", не смогла записать %d", st.failed)
		}
		if st.offline > 0 {
			msg += fmt.Sprintf(", источники не ответили по %d (повторю позже)", st.offline)
		}
		log.Print("хранитель " + msg)
		_ = s.db.AddServerLog("info", "", "", msg, 0)
	}
	return nil
}

// search — поиск в интернете для песен без обложки: несколько работников, карточка «Ищу
// обложки» в окне (вкладка «Задачи» и шапка).
func (k *coverKeeper) search(ctx context.Context, need []localdb.CoverCandidate, dir string, st *coverPassStats) {
	s := k.s
	finder := k.newFinder()
	if len(finder.Sources) == 0 {
		return
	}
	today := k.now().Format("2006-01-02")

	job := s.jobs.beginAmbient("covers", "Ищу обложки")
	s.jobs.mu.Lock()
	job.Total = len(need)
	s.jobs.mu.Unlock()
	progress := func(failed bool) {
		s.jobs.mu.Lock()
		job.Done++
		if failed {
			job.Failed++
		}
		s.jobs.mu.Unlock()
	}

	sctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var (
		mu          sync.Mutex
		offlineRun  int
		wg          sync.WaitGroup
		work        = make(chan localdb.CoverCandidate)
		workerCount = coverWorkers
	)
	if len(need) < workerCount {
		workerCount = len(need)
	}
	for i := 0; i < workerCount; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for c := range work {
				if sctx.Err() != nil {
					continue // круг прерван — остаток просто вычитываем
				}
				res, err := finder.Find(sctx, c.Artist, c.Title)
				mu.Lock()
				switch {
				case errors.Is(err, coverfind.ErrOffline):
					st.offline++
					offlineRun++
					if offlineRun >= coverOfflineStop {
						cancel()
					}
					mu.Unlock()
					progress(true)
					continue
				case err != nil:
					mu.Unlock() // отмена круга
					continue
				}
				offlineRun = 0
				mu.Unlock()
				marker := "found"
				if res == nil {
					// Обложки песни нет нигде — фото исполнителя (27.09.2026, Alex «делай так»).
					if a, aerr := finder.FindArtist(sctx, c.Artist); aerr == nil && a != nil {
						res, marker = a, "artist"
					}
				}
				if res == nil {
					mu.Lock()
					st.none++
					mu.Unlock()
					k.mark(c.ID, "none@"+today)
					progress(false)
					continue
				}
				if err := writeFoundCover(dir, c.ID, res.JPEG); err != nil {
					log.Printf("хранитель обложек: не записала обложку %s: %v", c.ID, err)
					mu.Lock()
					st.failed++
					mu.Unlock()
					progress(true)
					continue
				}
				k.mark(c.ID, marker)
				mu.Lock()
				if marker == "artist" {
					st.artist++
				} else {
					st.fetched++
				}
				mu.Unlock()
				progress(false)
			}
		}()
	}
feed:
	for _, c := range need {
		select {
		case work <- c:
		case <-sctx.Done():
			break feed
		}
	}
	close(work)
	wg.Wait()

	note := fmt.Sprintf("нашла %d, фото исполнителя %d, не нашла %d", st.fetched, st.artist, st.none)
	if st.offline > 0 {
		note += fmt.Sprintf(", без ответа %d", st.offline)
	}
	s.jobs.finishAmbient(job, note)
}

func hasEmbeddedCover(local string) bool {
	_, _, ok := coverart.Embedded(local)
	return ok
}

func hasFolderCover(local string) bool {
	_, ok := coverart.FolderImage(local)
	return ok
}

func hasFoundCover(dir, id string) bool {
	_, ok := coverart.Found(dir, id)
	return ok
}

// writeFoundCover — положить найденную обложку в found_covers/<id>.jpg: сначала во временный
// файл, потом переименовать, чтобы телефон/окно не увидели недописанную картинку.
func writeFoundCover(dir, id string, jpg []byte) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	final := filepath.Join(dir, filepath.Base(id)+".jpg")
	tmp := final + ".tmp"
	if err := os.WriteFile(tmp, jpg, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, final); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
