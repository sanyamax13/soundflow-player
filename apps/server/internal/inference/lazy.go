package inference

import (
	"errors"
	"sync"
	"time"
)

// embedder — то, что Lazy держит внутри: настоящая модель ([Engine]) или подмена в тестах.
type embedder interface {
	Embed(pcm []float32) ([]float32, error)
	EmbedFile(path string) ([]float32, error)
	Close() error
}

// Lazy — модель отпечатков, которая грузится в память только когда нужна и выгружается
// после простоя (оптимизация 21.09.2026, Alex TG 20331 «максимальная оптимизация»).
//
// Раньше [Open] вызывался при запуске программы, и ~320 МБ модели (cnn14.onnx.data) висели в
// памяти всё время, хотя считает она отпечатки только когда появилась новая песня, раз в
// неделю — сторож по звуку, раз в сутки — «Волна». Теперь: первая же работа загружает модель
// (около секунды), а если [Lazy.idle] прошло без дела — выгружает и память возвращается системе.
//
// Потокобезопасен. Пока идёт хоть один расчёт, модель не выгружается. Методы те же, что у
// [Engine] (Embed, EmbedFile, Close), поэтому вызывающий код менялся минимально.
type Lazy struct {
	dir  string
	idle time.Duration
	open func(dir string) (embedder, error)

	mu     sync.Mutex
	eng    embedder
	users  int
	gen    uint64 // растёт при каждом обращении; таймер выгрузки выгружает, только если с его старта никто не приходил
	timer  *time.Timer
	closed bool
}

var errLazyClosed = errors.New("модель отпечатков закрыта")

// NewLazy находит файлы модели (та же проверка, что у [Open]), но НЕ загружает её.
// Нет файлов — ошибка, как у Open: вызывающий тогда работает «без модели».
// idle <= 0 — не выгружать никогда (как раньше: загрузили и держим).
func NewLazy(assetsDir string, idle time.Duration) (*Lazy, error) {
	dir, err := resolveAssets(assetsDir)
	if err != nil {
		return nil, err
	}
	return newLazy(dir, idle, func(d string) (embedder, error) {
		e, err := Open(d)
		if err != nil {
			return nil, err
		}
		return e, nil
	}), nil
}

func newLazy(dir string, idle time.Duration, open func(dir string) (embedder, error)) *Lazy {
	return &Lazy{dir: dir, idle: idle, open: open}
}

// Loaded — сейчас модель в памяти? (для диагностики в окне)
func (l *Lazy) Loaded() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.eng != nil
}

// acquire берёт модель в работу (при необходимости загружает) и помечает «занята».
func (l *Lazy) acquire() (embedder, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil, errLazyClosed
	}
	l.gen++
	if l.timer != nil {
		l.timer.Stop()
		l.timer = nil
	}
	if l.eng == nil {
		e, err := l.open(l.dir)
		if err != nil {
			return nil, err // неудачную загрузку не запоминаем: следующее обращение попробует снова
		}
		l.eng = e
	}
	l.users++
	return l.eng, nil
}

// release отдаёт модель; когда последний пользователь ушёл — заводит таймер выгрузки.
func (l *Lazy) release() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.users--
	if l.users > 0 {
		return
	}
	if l.closed { // Close позвали, пока шёл расчёт: закрываем, когда последний закончил
		if l.eng != nil {
			_ = l.eng.Close()
			l.eng = nil
		}
		return
	}
	if l.idle <= 0 || l.eng == nil {
		return
	}
	l.gen++
	gen := l.gen
	l.timer = time.AfterFunc(l.idle, func() { l.unloadIfIdle(gen) })
}

// unloadIfIdle выгружает модель, если с момента заводки таймера её никто не брал.
func (l *Lazy) unloadIfIdle(gen uint64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed || l.users > 0 || l.gen != gen || l.eng == nil {
		return
	}
	_ = l.eng.Close()
	l.eng = nil
	l.timer = nil
}

// Embed — отпечаток по готовому моно-PCM 32 кГц.
func (l *Lazy) Embed(pcm []float32) ([]float32, error) {
	e, err := l.acquire()
	if err != nil {
		return nil, err
	}
	defer l.release()
	return e.Embed(pcm)
}

// EmbedFile — отпечаток по файлу: декодирование + Embed. Модель занята на всё время расчёта.
func (l *Lazy) EmbedFile(path string) ([]float32, error) {
	e, err := l.acquire()
	if err != nil {
		return nil, err
	}
	defer l.release()
	return e.EmbedFile(path)
}

// Close выгружает модель и запрещает дальнейшее использование. Не ждёт текущих расчётов:
// если кто-то ещё считает, модель закроется, когда он закончит (см. release).
func (l *Lazy) Close() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closed = true
	if l.timer != nil {
		l.timer.Stop()
		l.timer = nil
	}
	if l.eng != nil && l.users == 0 {
		err := l.eng.Close()
		l.eng = nil
		return err
	}
	return nil
}
