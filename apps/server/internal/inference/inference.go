package inference

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"

	ort "github.com/yalue/onnxruntime_go"
)

// Engine — загруженная модель CNN14 (ONNX). Потокобезопасен: Run сериализуется
// мьютексом (одна ORT-сессия, нам хватает — расчёт идёт фоновой очередью).
type Engine struct {
	mu   sync.Mutex
	sess *ort.DynamicAdvancedSession
}

var initOnce sync.Once
var initErr error

// Assets — где лежат onnxruntime.dll и cnn14.onnx (+ cnn14.onnx.data).
// Порядок поиска: явный аргумент -> $SOUNDFLOW_ASSETS -> рядом с exe -> ./.
func resolveAssets(dir string) (string, error) {
	cands := []string{dir, os.Getenv("SOUNDFLOW_ASSETS")}
	if exe, err := os.Executable(); err == nil {
		cands = append(cands, filepath.Dir(exe))
	}
	cands = append(cands, ".")
	for _, d := range cands {
		if d == "" {
			continue
		}
		if _, err := os.Stat(filepath.Join(d, "cnn14.onnx")); err == nil {
			if _, err := os.Stat(filepath.Join(d, dllName)); err == nil {
				return d, nil
			}
		}
	}
	return "", fmt.Errorf("не найдены cnn14.onnx и %s (искал: %v)", dllName, cands)
}

// Open поднимает ORT-окружение (один раз на процесс) и открывает сессию.
func Open(assetsDir string) (*Engine, error) {
	dir, err := resolveAssets(assetsDir)
	if err != nil {
		return nil, err
	}
	initOnce.Do(func() {
		ort.SetSharedLibraryPath(filepath.Join(dir, dllName))
		initErr = ort.InitializeEnvironment()
	})
	if initErr != nil {
		return nil, fmt.Errorf("ORT init: %w", initErr)
	}

	// Вход динамической длины (у каждого трека свой размер PCM). С включённым
	// CPU-арена-аллокатором и планировщиком mem-pattern ORT кэширует буферы под
	// каждый новый максимум длины и НЕ отдаёт их назад — на прогоне всей базы
	// это растекается в десятки ГБ. Отключаем оба; тогда память держится ровно.
	opts, err := ort.NewSessionOptions()
	if err != nil {
		return nil, fmt.Errorf("session options: %w", err)
	}
	defer opts.Destroy()
	if err := opts.SetCpuMemArena(false); err != nil {
		return nil, fmt.Errorf("SetCpuMemArena: %w", err)
	}
	if err := opts.SetMemPattern(false); err != nil {
		return nil, fmt.Errorf("SetMemPattern: %w", err)
	}
	// Ограничиваем пул потоков: без лимита ORT берёт все ядра и на длинных STFT
	// раздувает scratch. 4 достаточно, расчёт всё равно сериализован мьютексом.
	if err := opts.SetIntraOpNumThreads(4); err != nil {
		return nil, fmt.Errorf("SetIntraOpNumThreads: %w", err)
	}

	sess, err := ort.NewDynamicAdvancedSession(
		filepath.Join(dir, "cnn14.onnx"),
		[]string{"waveform"}, []string{"embedding"}, opts)
	if err != nil {
		return nil, fmt.Errorf("сессия cnn14.onnx: %w", err)
	}
	return &Engine{sess: sess}, nil
}

func (e *Engine) Close() error {
	if e == nil || e.sess == nil {
		return nil
	}
	return e.sess.Destroy()
}

// Embed прогоняет моно-PCM 32 кГц через CNN14 и возвращает 2048-мерный
// отпечаток (penultimate layer) — тот же, что писал Python-сайдкар.
func (e *Engine) Embed(pcm []float32) ([]float32, error) {
	if len(pcm) == 0 {
		return nil, fmt.Errorf("пустой PCM")
	}
	in, err := ort.NewTensor(ort.NewShape(1, int64(len(pcm))), pcm)
	if err != nil {
		return nil, err
	}
	defer in.Destroy()

	e.mu.Lock()
	defer e.mu.Unlock()

	outs := []ort.Value{nil}
	if err := e.sess.Run([]ort.Value{in}, outs); err != nil {
		return nil, err
	}
	out := outs[0]
	defer out.Destroy()

	t, ok := out.(*ort.Tensor[float32])
	if !ok {
		return nil, fmt.Errorf("неожиданный тип выхода: %T", out)
	}
	src := t.GetData()
	emb := make([]float32, len(src))
	copy(emb, src)
	return emb, nil
}

// EmbedFile — удобный путь: декод файла + Embed.
func (e *Engine) EmbedFile(path string) ([]float32, error) {
	pcm, err := DecodePCM(path)
	if err != nil {
		return nil, err
	}
	return e.Embed(pcm)
}
