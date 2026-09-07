//go:build !windows

package inference

// На не-Windows onnxruntime зовётся иначе; SoundFlow пока только под Windows,
// но пусть пакет собирается для тестов на CI.
const dllName = "libonnxruntime.so"
