//go:build windows

package inference

import (
	"os"
	"runtime/debug"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// Настоящая модель: возвращает ли выгрузка память системе. Включается вручную (грузит ~320 МБ):
//
//	SOUNDFLOW_REAL_MODEL_TEST=1 SOUNDFLOW_ASSETS=C:\Users\brain\Desktop\SoundFlow go test ./internal/inference -run RealModel -v
type processMemoryCounters struct {
	cb                         uint32
	PageFaultCount             uint32
	PeakWorkingSetSize         uintptr
	WorkingSetSize             uintptr
	QuotaPeakPagedPoolUsage    uintptr
	QuotaPagedPoolUsage        uintptr
	QuotaPeakNonPagedPoolUsage uintptr
	QuotaNonPagedPoolUsage     uintptr
	PagefileUsage              uintptr
	PeakPagefileUsage          uintptr
}

func workingSetMB(t *testing.T) int {
	t.Helper()
	proc := syscall.NewLazyDLL("psapi.dll").NewProc("GetProcessMemoryInfo")
	h, err := syscall.GetCurrentProcess()
	if err != nil {
		t.Fatal(err)
	}
	var m processMemoryCounters
	m.cb = uint32(unsafe.Sizeof(m))
	if r, _, e := proc.Call(uintptr(h), uintptr(unsafe.Pointer(&m)), uintptr(m.cb)); r == 0 {
		t.Fatalf("GetProcessMemoryInfo: %v", e)
	}
	return int(m.WorkingSetSize >> 20)
}

func TestLazy_RealModelReleasesMemory(t *testing.T) {
	if os.Getenv("SOUNDFLOW_REAL_MODEL_TEST") == "" {
		t.Skip("ручной замер: SOUNDFLOW_REAL_MODEL_TEST=1 и SOUNDFLOW_ASSETS=папка с cnn14.onnx")
	}
	l, err := NewLazy(os.Getenv("SOUNDFLOW_ASSETS"), 1500*time.Millisecond)
	if err != nil {
		t.Skipf("нет файлов модели: %v", err)
	}
	before := workingSetMB(t)
	if l.Loaded() {
		t.Fatal("после NewLazy модель не должна быть загружена")
	}

	pcm := make([]float32, 32000*5) // 5 секунд тишины/шума
	for i := range pcm {
		pcm[i] = float32((i*7919)%2001-1000) / 40000
	}
	t0 := time.Now()
	emb, err := l.Embed(pcm)
	if err != nil {
		t.Fatal(err)
	}
	loadMs := time.Since(t0).Milliseconds()
	withModel := workingSetMB(t)
	t.Logf("первый расчёт (с загрузкой модели): %d мс, отпечаток %d чисел", loadMs, len(emb))

	t1 := time.Now()
	if _, err := l.Embed(pcm); err != nil {
		t.Fatal(err)
	}
	t.Logf("второй расчёт (модель уже в памяти): %d мс", time.Since(t1).Milliseconds())

	deadline := time.Now().Add(10 * time.Second)
	for l.Loaded() && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if l.Loaded() {
		t.Fatal("модель не выгрузилась за 10 секунд")
	}
	debug.FreeOSMemory()
	time.Sleep(500 * time.Millisecond)
	after := workingSetMB(t)
	t.Logf("рабочий набор процесса: до %d МБ, с моделью %d МБ, после выгрузки %d МБ", before, withModel, after)

	t2 := time.Now()
	emb2, err := l.Embed(pcm)
	if err != nil {
		t.Fatalf("после выгрузки расчёт должен загрузить модель снова: %v", err)
	}
	t.Logf("расчёт после выгрузки (повторная загрузка): %d мс", time.Since(t2).Milliseconds())
	for i := range emb {
		if emb[i] != emb2[i] {
			t.Fatalf("отпечаток после перезагрузки модели отличается в позиции %d: %v и %v", i, emb[i], emb2[i])
		}
	}
	_ = l.Close()

	if withModel-before < 100 {
		t.Skipf("модель не заметно выросла в памяти (%d → %d МБ) — замер неинформативен", before, withModel)
	}
	if freed := withModel - after; freed < (withModel-before)/2 {
		t.Errorf("выгрузка вернула системе только %d МБ из %d", freed, withModel-before)
	}
}
