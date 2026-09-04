// Package pathmap переводит «канонические» пути (которые отдаёт Python-сайдкар и
// хранит БД) в реальные физические пути на текущей машине. Перенос swap_root из
// старого sidecar/config.py.
//
// Сайдкар на fg физически пишет в D:\SoundFlow\cache, но отдаёт API канонический
// E:\soundflow-data\cache. Go-сервер на fg должен открыть файл по реальному пути.
// Если пары не заданы — всё это no-op (канонический путь == реальный).
package pathmap

import (
	"path/filepath"
	"strings"
)

// Pair — одно соответствие «канонический корень → реальный корень».
type Pair struct {
	Canonical string
	Local     string
}

// Mapper держит список пар и переводит путь в реальный.
type Mapper struct {
	pairs []Pair
}

func New(pairs ...Pair) Mapper {
	clean := make([]Pair, 0, len(pairs))
	for _, p := range pairs {
		if p.Canonical == "" || p.Local == "" {
			continue
		}
		clean = append(clean, Pair{Canonical: filepath.Clean(p.Canonical), Local: filepath.Clean(p.Local)})
	}
	return Mapper{pairs: clean}
}

// ToLocal переводит канонический путь в реальный по первой подходящей паре.
// Путь вне всех корней возвращается как есть.
func (m Mapper) ToLocal(canonical string) string {
	if canonical == "" {
		return canonical
	}
	for _, p := range m.pairs {
		if out, ok := swapRoot(canonical, p.Canonical, p.Local); ok {
			return out
		}
	}
	return canonical
}

// swapRoot меняет корневой префикс fromRoot на toRoot, сохраняя хвост как есть.
// ok=false — путь не внутри fromRoot. Сравнение регистронезависимое (Windows fs).
func swapRoot(path, fromRoot, toRoot string) (string, bool) {
	p := filepath.Clean(path)
	if strings.EqualFold(p, fromRoot) {
		return toRoot, true
	}
	prefix := fromRoot + string(filepath.Separator)
	if len(p) > len(prefix) && strings.EqualFold(p[:len(prefix)], prefix) {
		return filepath.Join(toRoot, p[len(prefix):]), true
	}
	return path, false
}
