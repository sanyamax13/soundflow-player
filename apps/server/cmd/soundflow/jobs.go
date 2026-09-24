package main

import (
	"bytes"
	"context"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dhowden/tag"

	"soundflow/server/internal/cuesplit"
	"soundflow/server/internal/localdb"
	"soundflow/server/internal/proc"
	"soundflow/server/internal/quality"
	"soundflow/server/internal/tagfix"
	"soundflow/server/internal/waveform"
)

// JobRunner — фоновые задачи с прогрессом для окна. Скан папки и пересчёт
// отпечатков — по одной штуке одновременно (jr.cur), «Стоп» их отменяет.
// Скачивание («Найти трек», торрент-альбом) может идти сразу несколько штук
// параллельно — для них jr.extra: карточка прогресса на время работы, без
// эксклюзивности и без «Стоп» (Alex TG 14.09.2026: «показывать все
// прогресс бары, тот же отпечаток» — до этого качалка прогресс не показывала).
type JobRunner struct {
	svc   *Service
	mu    sync.Mutex
	cur   *Job
	extra map[string]*Job
	seq   int // счётчик для ID: часы Windows тикают крупно, две задачи подряд получали одинаковое время
}

// newIDLocked — уникальный ID задачи (под jr.mu). Раньше был «вид_время в наносекундах»: две задачи, начатые в один
// тик часов, получали один ID и затирали друг друга в списке.
func (jr *JobRunner) newIDLocked(kind string) string {
	jr.seq++
	return fmt.Sprintf("%s_%d_%d", kind, time.Now().UnixNano(), jr.seq)
}

type Job struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"` // scan | reindex | acquire | torrent | covers
	Label     string    `json:"label"`
	Total     int       `json:"total"`
	Done      int       `json:"done"`
	Failed    int       `json:"failed"`
	Running   bool      `json:"running"`
	StartedAt time.Time `json:"started_at"`
	Note      string    `json:"note"`
	// Итог не исчезает (ревизия 20.09.2026, шаг 2, С4): задачу, которую запустил сам Alex (скачать песню/альбом, скан
	// папки, пересчёт), после конца не убираем, а держим карточкой «Готово / Не вышло» до кнопки «Понятно». Фоновые
	// задачи по таймеру (обложки, сверка) карточек не оставляют — иначе окно завалит итогами того, о чём Alex не просил.
	Keep       bool       `json:"keep"`
	Outcome    string     `json:"outcome,omitempty"` // ok | fail — чем кончилась; пока идёт — пусто
	FinishedAt *time.Time `json:"finished_at,omitempty"`
	cancel     context.CancelFunc
}

const (
	jobKeepFor = 24 * time.Hour // карточку без «Понятно» держим не дольше суток
	jobKeepMax = 30             // и не больше стольких (самые старые уходят): «Скачать все» на сотню песен не завалит окно
)

func NewJobRunner(s *Service) *JobRunner { return &JobRunner{svc: s} }

func (jr *JobRunner) Status() []Job {
	jr.mu.Lock()
	defer jr.mu.Unlock()
	jr.pruneLocked()
	out := make([]Job, 0, len(jr.extra)+1)
	if jr.cur != nil {
		j := *jr.cur
		j.cancel = nil
		out = append(out, j)
	}
	for _, j := range jr.extra {
		cp := *j
		cp.cancel = nil
		out = append(out, cp)
	}
	sort.Slice(out, func(i, k int) bool { return out[i].StartedAt.Before(out[k].StartedAt) })
	return out
}

// beginAmbient — карточка прогресса для скачивания (acquire/torrent), без
// эксклюзивности: можно несколько сразу. Total не считаем (нет способа честно
// узнать долю прогресса на скачивании одного трека/альбома) — окно рисует
// индикатор-«крутилку» через тот же фолбэк, что и для scan/reindex без total.
func (jr *JobRunner) beginAmbient(kind, label string) *Job {
	jr.mu.Lock()
	defer jr.mu.Unlock()
	if jr.extra == nil {
		jr.extra = map[string]*Job{}
	}
	j := &Job{
		ID:   jr.newIDLocked(kind),
		Kind: kind, Label: label, Running: true,
		StartedAt: time.Now(),
		Keep:      kind == "acquire" || kind == "torrent", // запускает сам Alex; «covers» — по таймеру, без карточки
	}
	jr.extra[j.ID] = j
	return j
}

// finishAmbient — пометить готовой. Задача, запущенная самим Alex (Keep), остаётся карточкой итога до «Понятно»
// (Dismiss); фоновая — убирается через паузу, как раньше: успевает мигнуть в шапке и не захламляет.
func (jr *JobRunner) finishAmbient(j *Job, note string) { jr.finishAmbientAs(j, note, "ok") }

// failAmbient — то же, но итог «не вышло»: карточка с предупреждением.
func (jr *JobRunner) failAmbient(j *Job, note string) { jr.finishAmbientAs(j, note, "fail") }

func (jr *JobRunner) finishAmbientAs(j *Job, note, outcome string) {
	jr.mu.Lock()
	j.Running = false
	j.Note = note
	j.Outcome = outcome
	now := time.Now()
	j.FinishedAt = &now
	id, keep := j.ID, j.Keep
	jr.mu.Unlock()
	if keep {
		return
	}
	time.AfterFunc(8*time.Second, func() {
		jr.mu.Lock()
		delete(jr.extra, id)
		jr.mu.Unlock()
	})
}

// keep — пометить задачу «показать итог карточкой до «Понятно»» (её запустил сам Alex: кнопка скана/пересчёта в окне).
func (jr *JobRunner) keep(id string) {
	jr.mu.Lock()
	defer jr.mu.Unlock()
	if jr.cur != nil && jr.cur.ID == id {
		jr.cur.Keep = true
	}
	if j := jr.extra[id]; j != nil {
		j.Keep = true
	}
}

// Dismiss — «Понятно»: убрать карточки законченных задач. id пустой — все разом. Идущие задачи не трогает.
// Возвращает, сколько карточек убрано.
func (jr *JobRunner) Dismiss(id string) int {
	jr.mu.Lock()
	defer jr.mu.Unlock()
	n := 0
	for k, j := range jr.extra {
		if j.Running || !j.Keep || (id != "" && k != id) {
			continue
		}
		delete(jr.extra, k)
		n++
	}
	if c := jr.cur; c != nil && !c.Running && c.Keep && (id == "" || c.ID == id) {
		c.Keep = false // сама запись остаётся (её читает окно по старой схеме), карточка гаснет
		n++
	}
	return n
}

// pruneLocked — старые карточки итога (дольше суток) и сверх лимита уходят сами. Под jr.mu.
func (jr *JobRunner) pruneLocked() {
	var done []*Job
	for k, j := range jr.extra {
		if j.Running || !j.Keep {
			continue
		}
		if j.FinishedAt != nil && time.Since(*j.FinishedAt) > jobKeepFor {
			delete(jr.extra, k)
			continue
		}
		done = append(done, j)
	}
	if len(done) > jobKeepMax {
		sort.Slice(done, func(i, k int) bool { return finishedTime(done[i]).Before(finishedTime(done[k])) })
		for _, j := range done[:len(done)-jobKeepMax] {
			delete(jr.extra, j.ID)
		}
	}
}

func finishedTime(j *Job) time.Time {
	if j.FinishedAt != nil {
		return *j.FinishedAt
	}
	return j.StartedAt
}

func (jr *JobRunner) CancelAll() {
	jr.mu.Lock()
	defer jr.mu.Unlock()
	if jr.cur != nil && jr.cur.cancel != nil {
		jr.cur.cancel()
	}
}

func (jr *JobRunner) begin(kind, label string) (*Job, context.Context, bool) {
	jr.mu.Lock()
	defer jr.mu.Unlock()
	if jr.cur != nil && jr.cur.Running {
		return nil, nil, false
	}
	ctx, cancel := context.WithCancel(context.Background())
	j := &Job{
		ID:   jr.newIDLocked(kind),
		Kind: kind, Label: label, Running: true,
		StartedAt: time.Now(), cancel: cancel,
	}
	if old := jr.cur; old != nil && !old.Running && old.Keep {
		// итог прежнего скана/пересчёта, который Alex ещё не закрыл, не теряем — уходит в общий список карточек
		if jr.extra == nil {
			jr.extra = map[string]*Job{}
		}
		jr.extra[old.ID] = old
	}
	jr.cur = j
	return j, ctx, true
}

func (jr *JobRunner) finish(note string) { jr.finishAs(note, "ok") }

// finishFail — то же, но итог «не вышло».
func (jr *JobRunner) finishFail(note string) { jr.finishAs(note, "fail") }

func (jr *JobRunner) finishAs(note, outcome string) {
	jr.mu.Lock()
	defer jr.mu.Unlock()
	if jr.cur != nil {
		jr.cur.Running = false
		jr.cur.Note = note
		jr.cur.Outcome = outcome
		now := time.Now()
		jr.cur.FinishedAt = &now
	}
}

// ---------------- скан папки ----------------

var audioExt = map[string]string{
	".mp3": "audio/mpeg", ".flac": "audio/flac", ".m4a": "audio/mp4",
	".aac": "audio/aac", ".ogg": "audio/ogg", ".opus": "audio/opus",
	".wav": "audio/wav", ".wma": "audio/x-ms-wma",
}

// skipScanDir — папки, в которые скан не заходит: «_deleted» — сюда раньше переносилось удалённое из
// окна (с 20.09.2026 файлы стираются насовсем, но старые папки могут остаться). Без этого скан корня
// диска вернул бы перенесённые песни в базу (метка «больше не качать» их скрыла бы, но записи-призраки
// остались бы).
func skipScanDir(name string) bool { return strings.EqualFold(name, "_deleted") }

// scanFreshFor — файл, изменённый позже этого срока назад, скан пропускает: он ещё пишется (торрент качает
// альбом прямо в папку с музыкой, файл копируют), и недокачанное попало бы в каталог обрезком. Такой файл
// подхватит следующий скан (по таймеру, при возврате в окно, после торрент-скачивания — rescanSoon).
var scanFreshFor = 3 * time.Minute

func (jr *JobRunner) StartScan(dir string) string {
	j, ctx, ok := jr.begin("scan", "Скан папки "+dir)
	if !ok {
		return ""
	}
	go func() {
		s := jr.svc
		_ = s.db.AddServerLog("info", "", "", "скан папки: "+dir, 0)
		var added, skipped, failed, relinked int
		compDirs := map[string]string{} // папка → альбом-сборник («» — не сборник)
		// файлы, уже записанные в каталог под любым именем (см. localdb.KnownFilePaths)
		known, err := s.db.KnownFilePaths()
		if err != nil {
			_ = s.db.AddServerLog("error", "", "", "скан: не смог прочитать список известных файлов: "+err.Error(), 0)
		}
		// та же песня, уже в каталоге под чуть другим именем — «(Album Version)»,
		// «(feat. …)», слипшийся/разъехавшийся пробел (quality.FuzzyKey; Alex TG
		// 24.09.2026: «научи программу, чтобы сама определяла дубли»)
		fuzzy, ferr := s.db.FuzzyKnownKeys()
		if ferr != nil {
			_ = s.db.AddServerLog("error", "", "", "скан: не смог прочитать ключи для проверки дублей: "+ferr.Error(), 0)
		}
		_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				return nil
			}
			if d.IsDir() {
				if skipScanDir(d.Name()) {
					return fs.SkipDir
				}
				return nil
			}
			mime, isAudio := audioExt[strings.ToLower(filepath.Ext(path))]
			if !isAudio {
				return nil
			}
			if _, ok := known[localdb.PathKey(path)]; ok {
				j.Total++
				skipped++
				j.Done++
				return nil // этот файл уже в каталоге — теги не читаем, второй раз не добавляем
			}
			if fi, err := d.Info(); err == nil && time.Since(fi.ModTime()) < scanFreshFor {
				return nil // ещё пишется — заберём на следующем скане
			}
			if cuePath, cue, ok := cuesplit.FindFor(path); ok {
				n, f := splitByCue(s, path, cuePath, cue, fuzzy)
				added += n
				failed += f
				j.Total += n + f
				j.Done += n + f
				return nil
			}
			j.Total++
			ar, ti, al := resolveTags(path)
			if al == "" {
				al = compilationAlbum(compDirs, path)
			}
			if ar == "" || ti == "" {
				skipped++
				j.Done++
				return nil
			}
			if v := quality.Screen(ar, ti, ""); !v.OK {
				skipped++
				j.Done++
				return nil
			}
			key := quality.NormalizedKey(ar, ti)
			if exists, _ := s.db.TrackExistsByKey(key); exists {
				if s.relinkMoved(key, path) {
					relinked++ // песня уже была, её файл пропал с прежнего места, а здесь лежит — запись переехала
				}
				skipped++
				j.Done++
				return nil
			}
			if fzKey := quality.FuzzyKey(ar, ti); fuzzy[fzKey] != "" {
				// та же песня уже в каталоге под другим написанием («(Album Version)»,
				// «(feat. …)», «OneRepublic»/«One Republic») — не плодим вторую запись
				_ = s.db.AddServerLog("info", ar, ti, "похоже на дубль уже добавленной песни — пропущено: "+path, 0)
				skipped++
				j.Done++
				return nil
			}
			fi, _ := os.Stat(path)
			var size int64
			if fi != nil {
				size = fi.Size()
			}
			tid := "t_" + randHex()
			nt := localdb.NewTrack{
				ID: tid, Artist: ar, Title: ti, Album: al,
				ReleaseKind: quality.ReleaseKind(ti, al), NormalizedKey: key,
			}
			nf := localdb.NewTrackFile{
				ID: "f_" + randHex(), NormalizedKey: key, FilePath: path,
				MimeType: mime, SizeBytes: size, Source: "scan",
				DurationSec: probeDurationSec(path),
			}
			if err := s.db.InsertTrackWithFile(nt, nf); err != nil {
				failed++
				j.Failed++
				j.Done++
				return nil
			}
			fuzzy[quality.FuzzyKey(ar, ti)] = tid
			added++
			j.Done++
			// сразу считаем отпечаток, если модель есть
			if s.eng != nil {
				if emb, err := s.eng.EmbedFile(path); err == nil {
					_ = s.db.SetFeatureVector(tid, emb)
				}
			}
			return nil
		})
		note := fmt.Sprintf("добавлено %d, пропущено %d, ошибок %d", added, skipped, failed)
		if relinked > 0 {
			note += fmt.Sprintf(", перенесено %d", relinked)
		}
		_ = s.db.AddServerLog("info", "", "", "скан завершён: "+note, 0)
		jr.finish(note)
		if added > 0 {
			s.covers.Kick() // новые песни — сразу проверить обложки (coverkeeper.go)
		}
		s.recon.AfterScan() // и заодно сверить каталог с диском: пропавшие файлы убрать (reconcile.go)
	}()
	return j.ID
}

// splitByCue — альбом скачан/лежит ОДНИМ файлом, но рядом есть .cue-
// разметка (обычно так рипует Exact Audio Copy) — режем по её точным
// меткам вместо того, чтобы добавить весь альбом как одну «песню» (см.
// Alex TG 14.09.2026 — «Градусы», 3 альбома по 140-385 МБ одним файлом,
// отпечаток/обложка на них не считались, играть невозможно было по
// отдельной песне). Не трогаем исходный файл, если хоть что-то пошло не
// так — прячем (переименовываем расширение) только при полном успехе.
func splitByCue(s *Service, audioPath, cuePath string, cue *cuesplit.Cue, fuzzy map[string]string) (added, failed int) {
	cover := findCoverImage(filepath.Dir(audioPath))
	results, err := cuesplit.Split(proc.FFmpeg(), audioPath, cue, cover)
	if err != nil {
		_ = s.db.AddServerLog("error", "", "", "разрезка по cue не удалась ("+audioPath+"): "+err.Error(), 0)
		return 0, 1
	}
	mime := audioExt[strings.ToLower(filepath.Ext(audioPath))]
	for _, r := range results {
		ar := r.Track.Artist
		if ar == "" {
			ar = cue.AlbumArtist
		}
		ti := r.Track.Title
		al := cue.Album
		if v := quality.Screen(ar, ti, ""); !v.OK {
			continue
		}
		key := quality.NormalizedKey(ar, ti)
		if exists, _ := s.db.TrackExistsByKey(key); exists {
			continue
		}
		fzKey := quality.FuzzyKey(ar, ti)
		if fuzzy[fzKey] != "" {
			continue // та же песня уже в каталоге под другим написанием
		}
		fi, _ := os.Stat(r.Path)
		var size int64
		if fi != nil {
			size = fi.Size()
		}
		tid := "t_" + randHex()
		nt := localdb.NewTrack{
			ID: tid, Artist: ar, Title: ti, Album: al,
			ReleaseKind: quality.ReleaseKind(ti, al), NormalizedKey: key,
		}
		nf := localdb.NewTrackFile{
			ID: "f_" + randHex(), NormalizedKey: key, FilePath: r.Path,
			MimeType: mime, SizeBytes: size, Source: "scan",
			DurationSec: probeDurationSec(r.Path),
		}
		if err := s.db.InsertTrackWithFile(nt, nf); err != nil {
			failed++
			continue
		}
		fuzzy[fzKey] = tid
		added++
		if s.eng != nil {
			if emb, e := s.eng.EmbedFile(r.Path); e == nil {
				_ = s.db.SetFeatureVector(tid, emb)
			}
		}
	}
	if added > 0 {
		// прячем исходный слитый файл от будущих сканов — НЕ удаляем.
		_ = os.Rename(audioPath, audioPath+".orig")
	}
	_ = s.db.AddServerLog("info", "", "", fmt.Sprintf(
		"разрезано по cue: %s -> %d песен (%s)", filepath.Base(audioPath), added, filepath.Base(cuePath)), 0)
	return added, failed
}

var coverFileNames = map[string]bool{
	"folder.jpg": true, "folder.jpeg": true, "folder.png": true,
	"cover.jpg": true, "cover.jpeg": true, "cover.png": true,
}

func findCoverImage(dir string) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		if !e.IsDir() && coverFileNames[strings.ToLower(e.Name())] {
			return filepath.Join(dir, e.Name())
		}
	}
	return ""
}

// ---------------- пересчёт отпечатков ----------------

func (jr *JobRunner) StartReindex() string {
	j, ctx, ok := jr.begin("reindex", "Пересчёт отпечатков")
	if !ok {
		return ""
	}
	go func() {
		s := jr.svc
		ids, err := s.db.TrackIDsNeedingAnalysis(0)
		if err != nil {
			jr.finishFail("ошибка выборки: " + err.Error())
			return
		}
		j.Total = len(ids)
		_ = s.db.AddServerLog("info", "", "", fmt.Sprintf("пересчёт отпечатков/волн: %d треков", len(ids)), 0)
		var done, failed int
		// Первая причина сбоя — в итоговую строку журнала: раньше было только
		// «ошибок 5833», и по нему нельзя понять, что сломано (19.09.2026: у 97
		// песен на телефоне нет отпечатка, а пересчёт при запуске падал на всех).
		var firstErr string
		noteErr := func(what string, e error) {
			if firstErr == "" && e != nil {
				firstErr = what + ": " + e.Error()
			}
		}
		for _, id := range ids {
			if ctx.Err() != nil {
				break
			}
			path, ok, _ := s.db.TrackFilePath(id)
			if !ok {
				failed++
				j.Failed++
				j.Done++
				if firstErr == "" {
					firstErr = "у трека нет файла в базе"
				}
				continue
			}
			lp := s.localPath(path)
			okAny := false
			if _, hasVec, _ := s.db.FeatureVector(id); !hasVec {
				emb, e := s.eng.EmbedFile(lp)
				if e == nil && s.db.SetFeatureVector(id, emb) == nil {
					okAny = true
				} else {
					noteErr("отпечаток", e)
				}
			}
			if _, hasWf, _ := s.db.Waveform(id); !hasWf {
				// дешёвый декод (8 кГц) под полоску плеера — Alex TG 18994.
				wf, e := waveform.FromFile(lp, waveform.DefaultBars)
				if e == nil && len(wf) > 0 {
					_ = s.db.SetWaveform(id, wf)
					okAny = true
				} else {
					noteErr("волна", e)
				}
			}
			if okAny {
				done++
			} else {
				failed++
				j.Failed++
			}
			j.Done++
		}
		note := fmt.Sprintf("посчитано %d, ошибок %d", done, failed)
		if firstErr != "" {
			note += "; первая причина: " + firstErr
		}
		_ = s.db.AddServerLog("info", "", "", "пересчёт завершён: "+note, 0)
		jr.finish(note)
	}()
	return j.ID
}

var reDuration = regexp.MustCompile(`Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)`)

// probeDurationSec — длительность файла в секундах через ffmpeg (без
// ffprobe — его нет рядом с программой, а ffmpeg и так нужен для
// отпечатков/волны/разрезки по cue, см. internal/waveform,
// internal/cuesplit). `ffmpeg -i <file>` без выходного файла всегда
// возвращает ошибку — это ожидаемо, нужен только вывод в stderr, где он
// печатает "Duration: HH:MM:SS.xx".
func probeDurationSec(path string) int {
	cmd := proc.Quiet(exec.Command(proc.FFmpeg(), "-i", path))
	var errb bytes.Buffer
	cmd.Stderr = &errb
	_ = cmd.Run()
	m := reDuration.FindStringSubmatch(errb.String())
	if m == nil {
		return 0
	}
	h, _ := strconv.Atoi(m[1])
	mi, _ := strconv.Atoi(m[2])
	sec, _ := strconv.ParseFloat(m[3], 64)
	return h*3600 + mi*60 + int(sec+0.5)
}

// ---------------- теги / имя файла ----------------

func readTags(path string) (artist, title, album string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	m, err := tag.ReadFrom(f)
	if err != nil {
		return
	}
	return tagfix.Sanitize(m.Artist()), tagfix.Sanitize(m.Title()), tagfix.Sanitize(m.Album())
}

// resolveTags — исполнитель/название/альбом файла для каталога: берём теги, а где
// они пусты или это болванка «Track N» — разбираем имя файла. Налипший номер
// трека срезаем на ОБОИХ путях: и из тега, и из имени файла («01. Deja Vu -
// Unbreak My Heart.mp3» → исполнитель «Deja Vu»). Раньше срез стоял только на
// пути «из тега», и сборники с пустыми тегами попадали в каталог с исполнителем
// «01. Deja Vu» (Alex TG 19970, 19.09.2026).
func resolveTags(path string) (artist, title, album string) {
	artist, title, album = readTags(path)
	artist = quality.StripLeadingTrackNumber(artist)
	if artist == "" || title == "" || quality.IsGenericTrackTitle(title) {
		a2, t2 := fromFilename(path)
		if artist == "" {
			artist = quality.StripLeadingTrackNumber(a2)
		}
		if (title == "" || quality.IsGenericTrackTitle(title)) && t2 != "" {
			title = t2
		}
	}
	return artist, title, album
}

// compilationAlbum — альбом для песни без тега «альбом», лежащей в папке-сборнике
// (имена файлов с номерами по порядку — см. quality.LooksLikeNumberedAlbum):
// имя папки. Так весь сборник собирается в одну плитку каталога, а не в
// россыпь «синглов» (Alex TG 19970, 19.09.2026: «в одну плитку»). Решение по
// папке считаем один раз и помним в cache; пусто — не сборник.
func compilationAlbum(cache map[string]string, path string) string {
	dir := filepath.Dir(path)
	if v, ok := cache[dir]; ok {
		return v
	}
	v := ""
	if quality.LooksLikeNumberedAlbum(audioNamesIn(dir)) {
		v = quality.AlbumFromFolder(dir)
	}
	cache[dir] = v
	return v
}

// audioNamesIn — имена аудиофайлов прямо в папке (без вложенных папок).
func audioNamesIn(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if _, ok := audioExt[strings.ToLower(filepath.Ext(e.Name()))]; ok {
			names = append(names, e.Name())
		}
	}
	return names
}

func fromFilename(path string) (artist, title string) {
	base := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	// «Artist - Title» / «NN - Title» / «Artist — Title»
	for _, sep := range []string{" - ", " — ", " – ", " -- "} {
		if i := strings.Index(base, sep); i > 0 {
			a := strings.TrimSpace(base[:i])
			t := strings.TrimSpace(base[i+len(sep):])
			if isNumeric(a) {
				return "", t
			}
			return a, t
		}
	}
	return "", strings.TrimSpace(base)
}

func isNumeric(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
