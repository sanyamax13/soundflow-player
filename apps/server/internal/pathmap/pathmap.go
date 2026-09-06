// Package pathmap переводит «канонические» пути (которые отдаёт Python-сайдкар и
// хранит БД) в реальные физические пути на текущей машине. Перенос swap_root из
// старого sidecar/config.py.
//
// Сайдкар на fg физически пишет в D:\SoundFlow\cache, но отдаёт API канонический
// E:\soundflow-data\cache. Go-сервер на fg должен открыть файл по реальному пути.
// Если пары не заданы — всё это no-op (канонический путь == реальный).
package pathmap

import (
	"fmt"
	"os"
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

// LocalRoots — реальные корни на этой машине (правая часть всех пар).
// Пригодится для разового обхода файлов на диске (импорт старой библиотеки).
func (m Mapper) LocalRoots() []string {
	out := make([]string, 0, len(m.pairs))
	for _, p := range m.pairs {
		out = append(out, p.Local)
	}
	return out
}

// ToCanonical — обратный перевод: реальный путь на этой машине → канонический
// для хранения в БД. Нужен при переносе уже лежащих на диске файлов (импорт
// старой библиотеки), а не полученных от сайдкара.
func (m Mapper) ToCanonical(local string) string {
	if local == "" {
		return local
	}
	for _, p := range m.pairs {
		if out, ok := swapRoot(local, p.Local, p.Canonical); ok {
			return out
		}
	}
	return local
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

// MoveToTrash переносит файл в «_trash» рядом с тем корнем библиотеки, под
// которым он лежит (не удаляет — на случай ошибки распознавания трека).
// Общая для ручного удаления с телефона (sync/events) и для чистки мусора
// по правилам (Screen).
func MoveToTrash(m Mapper, local string) error {
	if local == "" {
		return fmt.Errorf("пустой путь")
	}
	for _, root := range m.LocalRoots() {
		rel, err := filepath.Rel(root, local)
		if err != nil || strings.HasPrefix(rel, "..") {
			continue
		}
		dest := filepath.Join(root, "_trash", rel)
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return err
		}
		return os.Rename(local, dest)
	}
	return fmt.Errorf("файл вне известных корней библиотеки")
}

// DeleteForever — стереть файл трека насовсем, без переноса в «_trash»
// (Alex 06.09.2026: удаление навсегда). Нет файла — не ошибка. Строку трека
// в БД и метку blocked ставит вызывающий.
func DeleteForever(local string) error {
	if local == "" {
		return fmt.Errorf("пустой путь")
	}
	if err := os.Remove(local); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// PurgeTrash — стереть НАСОВСЕМ всё, что лежит в «_trash» рядом с каждым
// корнем библиотеки (Alex 06.09.2026: удаление навсегда, без хранения на
// 7 дней). Возвращает число удалённых файлов. Метки blocked в legacy_marks
// не трогает — трек остаётся в списке «больше не качать».
func PurgeTrash(m Mapper) (int, error) {
	n := 0
	for _, root := range m.LocalRoots() {
		trashDir := filepath.Join(root, "_trash")
		_ = filepath.WalkDir(trashDir, func(_ string, d os.DirEntry, err error) error {
			if err == nil && d != nil && !d.IsDir() {
				n++
			}
			return nil
		})
		if err := os.RemoveAll(trashDir); err != nil && !os.IsNotExist(err) {
			return n, err
		}
	}
	return n, nil
}

// RestoreFromTrash — обратное действие к MoveToTrash: local — исходный путь
// файла (как он лежит в БД, ДО переноса в корзину); функция сама находит его
// в «_trash» рядом с нужным корнем и кладёт назад.
func RestoreFromTrash(m Mapper, local string) error {
	if local == "" {
		return fmt.Errorf("пустой путь")
	}
	for _, root := range m.LocalRoots() {
		rel, err := filepath.Rel(root, local)
		if err != nil || strings.HasPrefix(rel, "..") {
			continue
		}
		trashPath := filepath.Join(root, "_trash", rel)
		if _, err := os.Stat(trashPath); err != nil {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
			return err
		}
		return os.Rename(trashPath, local)
	}
	return fmt.Errorf("файла нет в корзине")
}
