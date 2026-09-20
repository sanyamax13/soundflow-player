package localdb

import (
	"path/filepath"
	"strings"
)

// PathKey — путь для сравнения «это тот же файл?»: без учёта регистра (Windows: `G:\Музыка` и
// `G:\музыка` — одна папка) и вида слэшей.
func PathKey(p string) string {
	return strings.ToLower(filepath.ToSlash(filepath.Clean(p)))
}

// KnownFilePaths — все файлы, уже записанные в каталог (и отклонённые тоже), по PathKey.
// Скан по нему пропускает файл, который уже есть в каталоге под любым именем: скачанная песня
// записывается с официальным названием Яндекса («Аквариум — Город золотой»), а файл лежит под
// именем из запроса («Аквариум - Город.mp3») — без этой проверки скан при следующем запуске
// читал имя из файла, ключ не совпадал, и та же песня добавлялась вторым разом (20.09.2026:
// три дубля сразу после замены программы).
func (d *DB) KnownFilePaths() (map[string]struct{}, error) {
	rows, err := d.sql.Query(`SELECT file_path FROM track_files`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]struct{}{}
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, err
		}
		if p != "" {
			out[PathKey(p)] = struct{}{}
		}
	}
	return out, rows.Err()
}
