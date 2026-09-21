package inference

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeModel — подмена настоящей модели: считает загрузки/выгрузки и может «считать долго».
type fakeModel struct {
	closed  atomic.Bool
	compute time.Duration
}

func (f *fakeModel) Embed(pcm []float32) ([]float32, error) {
	if f.closed.Load() {
		return nil, errors.New("модель уже выгружена посреди расчёта")
	}
	time.Sleep(f.compute)
	if f.closed.Load() {
		return nil, errors.New("модель выгружена посреди расчёта")
	}
	return []float32{float32(len(pcm))}, nil
}

func (f *fakeModel) EmbedFile(path string) ([]float32, error) { return f.Embed([]float32{1, 2, 3}) }

func (f *fakeModel) Close() error {
	f.closed.Store(true)
	return nil
}

// counter — открывалка с подсчётом: сколько раз загрузили и какие модели живы.
type counter struct {
	mu      sync.Mutex
	opened  int
	models  []*fakeModel
	failing bool
	compute time.Duration
}

func (c *counter) open(string) (embedder, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.failing {
		return nil, errors.New("не удалось загрузить")
	}
	c.opened++
	m := &fakeModel{compute: c.compute}
	c.models = append(c.models, m)
	return m, nil
}

func (c *counter) openedCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.opened
}

func (c *counter) aliveCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, m := range c.models {
		if !m.closed.Load() {
			n++
		}
	}
	return n
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("не дождались: %s", what)
}

func TestLazy_НеГрузитсяПокаНеНужна(t *testing.T) {
	c := &counter{}
	l := newLazy("x", time.Minute, c.open)
	if c.openedCount() != 0 || l.Loaded() {
		t.Fatalf("модель загрузилась без обращения: opened=%d loaded=%v", c.openedCount(), l.Loaded())
	}
	if _, err := l.Embed([]float32{1}); err != nil {
		t.Fatal(err)
	}
	if c.openedCount() != 1 || !l.Loaded() {
		t.Fatalf("после первого обращения модель должна быть в памяти: opened=%d loaded=%v", c.openedCount(), l.Loaded())
	}
}

func TestLazy_ПовторныеОбращенияНеГрузятЗаново(t *testing.T) {
	c := &counter{}
	l := newLazy("x", time.Minute, c.open)
	for i := 0; i < 5; i++ {
		if _, err := l.EmbedFile("a.mp3"); err != nil {
			t.Fatal(err)
		}
	}
	if c.openedCount() != 1 {
		t.Fatalf("модель грузилась %d раз, ждали 1", c.openedCount())
	}
}

func TestLazy_ВыгружаетсяПослеПростояИГрузитсяСноваПоНужде(t *testing.T) {
	c := &counter{}
	l := newLazy("x", 40*time.Millisecond, c.open)
	if _, err := l.Embed([]float32{1}); err != nil {
		t.Fatal(err)
	}
	eventually(t, "выгрузка после простоя", func() bool { return !l.Loaded() && c.aliveCount() == 0 })

	if _, err := l.Embed([]float32{1, 2}); err != nil {
		t.Fatalf("после выгрузки расчёт должен снова загрузить модель: %v", err)
	}
	if c.openedCount() != 2 || !l.Loaded() {
		t.Fatalf("ждали вторую загрузку: opened=%d loaded=%v", c.openedCount(), l.Loaded())
	}
}

func TestLazy_НеВыгружаетсяПокаИдётРасчёт(t *testing.T) {
	c := &counter{compute: 250 * time.Millisecond}
	l := newLazy("x", 20*time.Millisecond, c.open)
	// расчёт длится дольше времени простоя — таймера выгрузки на это время нет
	got, err := l.Embed([]float32{1, 2, 3})
	if err != nil {
		t.Fatalf("модель выгрузилась посреди расчёта: %v", err)
	}
	if len(got) != 1 || got[0] != 3 {
		t.Fatalf("неверный ответ: %v", got)
	}
}

func TestLazy_ЧастыеОбращенияДержатМодельЗагруженной(t *testing.T) {
	c := &counter{}
	l := newLazy("x", 120*time.Millisecond, c.open)
	// обращения чаще, чем время простоя — выгружаться нечему
	for i := 0; i < 8; i++ {
		if _, err := l.Embed([]float32{1}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(30 * time.Millisecond)
	}
	if c.openedCount() != 1 {
		t.Fatalf("модель перегружалась %d раз при частых обращениях, ждали 1", c.openedCount())
	}
}

func TestLazy_ПараллельныеРасчётыОднаЗагрузка(t *testing.T) {
	c := &counter{compute: 30 * time.Millisecond}
	l := newLazy("x", time.Minute, c.open)
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := l.Embed([]float32{1}); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if c.openedCount() != 1 {
		t.Fatalf("параллельные обращения загрузили модель %d раз, ждали 1", c.openedCount())
	}
}

func TestLazy_НеудачнаяЗагрузкаНеЗапоминается(t *testing.T) {
	c := &counter{failing: true}
	l := newLazy("x", time.Minute, c.open)
	if _, err := l.Embed([]float32{1}); err == nil {
		t.Fatal("ждали ошибку загрузки")
	}
	if l.Loaded() {
		t.Fatal("после неудачи модель не должна числиться загруженной")
	}
	c.mu.Lock()
	c.failing = false
	c.mu.Unlock()
	if _, err := l.Embed([]float32{1}); err != nil {
		t.Fatalf("следующее обращение должно попробовать снова: %v", err)
	}
}

func TestLazy_Close(t *testing.T) {
	c := &counter{}
	l := newLazy("x", time.Minute, c.open)
	if _, err := l.Embed([]float32{1}); err != nil {
		t.Fatal(err)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if c.aliveCount() != 0 || l.Loaded() {
		t.Fatalf("после Close модель должна быть выгружена: alive=%d loaded=%v", c.aliveCount(), l.Loaded())
	}
	if _, err := l.Embed([]float32{1}); err == nil {
		t.Fatal("после Close считать нельзя")
	}
	if err := l.Close(); err != nil {
		t.Fatalf("повторный Close не должен падать: %v", err)
	}
	var nilLazy *Lazy
	if err := nilLazy.Close(); err != nil {
		t.Fatalf("Close на nil не должен падать: %v", err)
	}
}

func TestLazy_CloseПокаИдётРасчёт(t *testing.T) {
	c := &counter{compute: 150 * time.Millisecond}
	l := newLazy("x", time.Minute, c.open)
	done := make(chan error, 1)
	go func() {
		_, err := l.Embed([]float32{1})
		done <- err
	}()
	eventually(t, "расчёт начался", func() bool { return c.openedCount() == 1 })
	_ = l.Close() // посреди расчёта
	if err := <-done; err != nil {
		t.Fatalf("Close посреди расчёта не должен ломать сам расчёт: %v", err)
	}
	eventually(t, "модель закрыта после конца расчёта", func() bool { return c.aliveCount() == 0 })
}

func TestLazy_НулевоеВремяПростояНеВыгружает(t *testing.T) {
	c := &counter{}
	l := newLazy("x", 0, c.open)
	if _, err := l.Embed([]float32{1}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(80 * time.Millisecond)
	if !l.Loaded() {
		t.Fatal("idle=0 означает «не выгружать никогда»")
	}
}

func TestNewLazy_НетФайловМодели(t *testing.T) {
	if _, err := NewLazy(t.TempDir(), time.Minute); err == nil {
		t.Skip("на этой машине модель нашлась рядом — проверка «нет файлов» неприменима")
	}
}
