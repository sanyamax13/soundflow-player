package main

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/dhowden/tag"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/quality"
	"soundflow/server/internal/waveform"
)

// JobRunner — одна фоновая задача одновременно (скан папки или пересчёт
// отпечатков). Прогресс виден в окне, «Стоп» отменяет.
type JobRunner struct {
	svc *Service
	mu  sync.Mutex
	cur *Job
}

type Job struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"` // scan | reindex
	Label     string    `json:"label"`
	Total     int       `json:"total"`
	Done      int       `json:"done"`
	Failed    int       `json:"failed"`
	Running   bool      `json:"running"`
	StartedAt time.Time `json:"started_at"`
	Note      string    `json:"note"`
	cancel    context.CancelFunc
}

func NewJobRunner(s *Service) *JobRunner { return &JobRunner{svc: s} }

func (jr *JobRunner) Status() []Job {
	jr.mu.Lock()
	defer jr.mu.Unlock()
	if jr.cur == nil {
		return []Job{}
	}
	j := *jr.cur
	j.cancel = nil
	return []Job{j}
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
		ID:   kind + "_" + fmt.Sprint(time.Now().UnixNano()),
		Kind: kind, Label: label, Running: true,
		StartedAt: time.Now(), cancel: cancel,
	}
	jr.cur = j
	return j, ctx, true
}

func (jr *JobRunner) finish(note string) {
	jr.mu.Lock()
	defer jr.mu.Unlock()
	if jr.cur != nil {
		jr.cur.Running = false
		jr.cur.Note = note
	}
}

// ---------------- скан папки ----------------

var audioExt = map[string]string{
	".mp3": "audio/mpeg", ".flac": "audio/flac", ".m4a": "audio/mp4",
	".aac": "audio/aac", ".ogg": "audio/ogg", ".opus": "audio/opus",
	".wav": "audio/wav", ".wma": "audio/x-ms-wma",
}

func (jr *JobRunner) StartScan(dir string) string {
	j, ctx, ok := jr.begin("scan", "Скан папки "+dir)
	if !ok {
		return ""
	}
	go func() {
		s := jr.svc
		_ = s.db.AddServerLog("info", "", "", "скан папки: "+dir, 0)
		var added, skipped, failed int
		_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil || d.IsDir() {
				return nil
			}
			mime, isAudio := audioExt[strings.ToLower(filepath.Ext(path))]
			if !isAudio {
				return nil
			}
			j.Total++
			ar, ti, al := readTags(path)
			if ar == "" || ti == "" {
				a2, t2 := fromFilename(path)
				if ar == "" {
					ar = a2
				}
				if ti == "" {
					ti = t2
				}
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
			}
			if err := s.db.InsertTrackWithFile(nt, nf); err != nil {
				failed++
				j.Failed++
				j.Done++
				return nil
			}
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
		_ = s.db.AddServerLog("info", "", "", "скан завершён: "+note, 0)
		jr.finish(note)
	}()
	return j.ID
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
			jr.finish("ошибка выборки: " + err.Error())
			return
		}
		j.Total = len(ids)
		_ = s.db.AddServerLog("info", "", "", fmt.Sprintf("пересчёт отпечатков/волн: %d треков", len(ids)), 0)
		var done, failed int
		for _, id := range ids {
			if ctx.Err() != nil {
				break
			}
			path, ok, _ := s.db.TrackFilePath(id)
			if !ok {
				failed++
				j.Failed++
				j.Done++
				continue
			}
			lp := s.localPath(path)
			okAny := false
			if _, hasVec, _ := s.db.FeatureVector(id); !hasVec {
				if emb, e := s.eng.EmbedFile(lp); e == nil && s.db.SetFeatureVector(id, emb) == nil {
					okAny = true
				}
			}
			if _, hasWf, _ := s.db.Waveform(id); !hasWf {
				// дешёвый декод (8 кГц) под полоску плеера — Alex TG 18994.
				if wf, e := waveform.FromFile(lp, waveform.DefaultBars); e == nil && len(wf) > 0 {
					_ = s.db.SetWaveform(id, wf)
					okAny = true
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
		_ = s.db.AddServerLog("info", "", "", "пересчёт завершён: "+note, 0)
		jr.finish(note)
	}()
	return j.ID
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
	return strings.TrimSpace(m.Artist()), strings.TrimSpace(m.Title()), strings.TrimSpace(m.Album())
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
