package main

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
)

// Итог не исчезает (ревизия 20.09.2026, шаг 2): задача, которую запустил сам Alex, после конца остаётся карточкой
// «Готово / Не вышло» до «Понятно»; фоновая по таймеру — уходит через паузу, как раньше.

func jobByID(list []Job, id string) (Job, bool) {
	for _, j := range list {
		if j.ID == id {
			return j, true
		}
	}
	return Job{}, false
}

func TestFinishedAcquireStaysUntilDismissed(t *testing.T) {
	jr := NewJobRunner(nil)
	ok := jr.beginAmbient("acquire", "Скачиваю: A — Хорошая")
	bad := jr.beginAmbient("acquire", "Скачиваю: B — Пропавшая")
	if !ok.Keep || !bad.Keep {
		t.Fatal("скачивание, запущенное Alex, должно оставлять карточку итога")
	}
	jr.finishAmbient(ok, "скачано: yandex")
	jr.failAmbient(bad, "не нашёл ни на одном источнике")

	got, found := jobByID(jr.Status(), ok.ID)
	if !found || got.Running || got.Outcome != "ok" || got.FinishedAt == nil || got.Note != "скачано: yandex" {
		t.Fatalf("итог «готово» потерялся: %+v found=%v", got, found)
	}
	got, found = jobByID(jr.Status(), bad.ID)
	if !found || got.Outcome != "fail" || got.Note != "не нашёл ни на одном источнике" {
		t.Fatalf("итог «не вышло» потерялся: %+v found=%v", got, found)
	}

	// одна карточка закрывается по id, вторая остаётся
	if n := jr.Dismiss(ok.ID); n != 1 {
		t.Errorf("Dismiss(id): убрано %d, ждали 1", n)
	}
	if _, found := jobByID(jr.Status(), ok.ID); found {
		t.Error("закрытая карточка всё ещё в списке")
	}
	if _, found := jobByID(jr.Status(), bad.ID); !found {
		t.Error("вторая карточка пропала вместе с первой")
	}
	// «Понятно» без id — все разом; повторно — уже нечего
	if n := jr.Dismiss(""); n != 1 {
		t.Errorf("Dismiss(\"\"): убрано %d, ждали 1", n)
	}
	if n := jr.Dismiss(""); n != 0 {
		t.Errorf("повторное «Понятно»: убрано %d, ждали 0", n)
	}
}

func TestDismissNeverTouchesRunningJobs(t *testing.T) {
	jr := NewJobRunner(nil)
	run := jr.beginAmbient("torrent", "Качаю альбом: X")
	if n := jr.Dismiss(""); n != 0 {
		t.Errorf("идущую задачу нельзя убрать «Понятно»: убрано %d", n)
	}
	if got, found := jobByID(jr.Status(), run.ID); !found || !got.Running {
		t.Errorf("идущая задача пропала: %+v", got)
	}
}

func TestBackgroundJobLeavesNoCard(t *testing.T) {
	jr := NewJobRunner(nil)
	j := jr.beginAmbient("covers", "Ищу обложки")
	if j.Keep {
		t.Fatal("обложки идут по таймеру — карточки итога быть не должно")
	}
	jr.finishAmbient(j, "нашла 3")
	if got, found := jobByID(jr.Status(), j.ID); !found || got.Running || got.Keep {
		t.Errorf("сразу после конца запись есть, но без карточки: %+v found=%v", got, found)
	}
}

func TestScanCardSurvivesNextScan(t *testing.T) {
	jr := NewJobRunner(nil)
	first, _, ok := jr.begin("scan", "Скан папки A")
	if !ok {
		t.Fatal("не начался скан")
	}
	jr.keep(first.ID) // как делает hScan
	jr.finish("добавлено 5, пропущено 0, ошибок 0")

	second, _, ok := jr.begin("scan", "Скан папки B")
	if !ok {
		t.Fatal("после конца первого скана второй должен начаться")
	}
	got, found := jobByID(jr.Status(), first.ID)
	if !found || !got.Keep || got.Outcome != "ok" {
		t.Fatalf("итог первого скана потерялся, когда пошёл второй: %+v found=%v", got, found)
	}
	if cur, found := jobByID(jr.Status(), second.ID); !found || !cur.Running {
		t.Errorf("второй скан не виден: %+v", cur)
	}
	jr.Dismiss(first.ID)
	if _, found := jobByID(jr.Status(), first.ID); found {
		t.Error("закрытый итог первого скана остался")
	}
}

func TestScanThatAutoStartedLeavesNoCard(t *testing.T) {
	jr := NewJobRunner(nil)
	j, _, _ := jr.begin("scan", "Скан папки по таймеру") // как из reconcile.go: без keep
	jr.finish("добавлено 0, пропущено 12, ошибок 0")
	got, found := jobByID(jr.Status(), j.ID)
	if !found || got.Keep {
		t.Errorf("автоскан не должен оставлять карточку: %+v", got)
	}
	if n := jr.Dismiss(""); n != 0 {
		t.Errorf("закрывать нечего, а убрано %d", n)
	}
}

func TestReindexFailureIsMarkedFail(t *testing.T) {
	jr := NewJobRunner(nil)
	j, _, _ := jr.begin("reindex", "Пересчёт отпечатков")
	jr.keep(j.ID)
	jr.finishFail("ошибка выборки: база занята")
	got, _ := jobByID(jr.Status(), j.ID)
	if got.Outcome != "fail" || !strings.Contains(got.Note, "база занята") || got.FinishedAt == nil {
		t.Errorf("итог сбоя: %+v", got)
	}
}

func TestOldCardsAreCleanedUp(t *testing.T) {
	jr := NewJobRunner(nil)
	old := jr.beginAmbient("acquire", "Скачиваю: старая")
	jr.finishAmbient(old, "скачано")
	past := time.Now().Add(-jobKeepFor - time.Hour)
	jr.mu.Lock()
	old.FinishedAt = &past
	jr.mu.Unlock()
	if _, found := jobByID(jr.Status(), old.ID); found {
		t.Error("карточка старше суток должна уйти сама")
	}

	// лимит: «Скачать все» на сотню песен не завалит окно — остаются самые свежие jobKeepMax
	var last *Job
	for i := 0; i < jobKeepMax+10; i++ {
		j := jr.beginAmbient("acquire", "Скачиваю: песня")
		jr.finishAmbient(j, "скачано")
		last = j
		time.Sleep(time.Millisecond) // разное время конца
	}
	list := jr.Status()
	kept := 0
	for _, j := range list {
		if j.Keep && !j.Running {
			kept++
		}
	}
	if kept != jobKeepMax {
		t.Errorf("карточек осталось %d, ждали %d", kept, jobKeepMax)
	}
	if _, found := jobByID(list, last.ID); !found {
		t.Error("самая свежая карточка пропала при чистке лимита")
	}
}

func TestDismissHandler(t *testing.T) {
	s := &Service{jobs: NewJobRunner(nil)}
	a := s.jobs.beginAmbient("acquire", "Скачиваю: A")
	b := s.jobs.beginAmbient("acquire", "Скачиваю: B")
	s.jobs.finishAmbient(a, "скачано")
	s.jobs.failAmbient(b, "не нашёл")

	r := chi.NewRouter()
	r.Delete("/api/jobs", s.hJobsDismiss)
	r.Delete("/api/jobs/{id}", s.hJobsDismiss)

	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest("DELETE", "/api/jobs/"+a.ID, nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"dismissed":1`) {
		t.Fatalf("DELETE по id: %d %s", rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest("DELETE", "/api/jobs", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"dismissed":1`) {
		t.Fatalf("DELETE все: %d %s", rec.Code, rec.Body.String())
	}
	if len(s.jobs.Status()) != 0 {
		t.Errorf("после «Понятно» карточек быть не должно: %+v", s.jobs.Status())
	}
}
