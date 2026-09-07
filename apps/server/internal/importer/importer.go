// Package importer — разовый перенос уже скачанной старым приложением музыки
// в новый каталог. Сервер и файлы — на одной машине (fg), поэтому читаем
// файлы напрямую: не качаем и не двигаем их, только смотрим теги и путь.
package importer

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/dhowden/tag"
	"golang.org/x/text/encoding/charmap"

	"soundflow/server/internal/db"
	"soundflow/server/internal/pathmap"
	"soundflow/server/internal/quality"
)

var audioExt = map[string]string{
	".mp3":  "audio/mpeg",
	".flac": "audio/flac",
	".m4a":  "audio/mp4",
	".m4b":  "audio/mp4",
	".ogg":  "audio/ogg",
	".wav":  "audio/wav",
}

var errSkip = errors.New("skip")

// Result — счётчики одного прогона Scan.
type Result struct {
	Scanned  int // всего аудиофайлов увидели
	Imported int // добавили в каталог
	Skipped  int // уже был / в чёрном списке / не разобрали имя / отсеян Screen
	Errors   int // не смогли прочитать файл или записать в базу
}

// Scan обходит roots (реальные пути на этой машине) и для каждого
// аудиофайла определяет артиста/название — сперва из тегов (ID3/FLAC/MP4),
// если пусто — из имени файла вида «Артист - Название». Не разобрали — файл
// пропускаем (не гадаем). Уже есть в каталоге (по normalized_key) или трек
// отмечен в legacy_marks как blocked (Alex его удалил/скрыл в старом
// плеере) — тоже пропускаем, старым удалениям не перечим.
func Scan(ctx context.Context, p Store, pm pathmap.Mapper, roots []string) (Result, error) {
	var res Result
	if p == nil {
		return res, errors.New("importer: нет базы")
	}
	for _, root := range roots {
		if root == "" {
			continue
		}
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if walkErr != nil {
				res.Errors++
				log.Printf("importer: %s: %v", path, walkErr)
				return nil // один плохой файл/папка не должен рвать весь обход
			}
			if d.IsDir() {
				return nil
			}
			mime, ok := audioExt[strings.ToLower(filepath.Ext(path))]
			if !ok {
				return nil
			}
			res.Scanned++
			switch err := importOne(ctx, p, pm, path, mime); {
			case err == nil:
				res.Imported++
			case errors.Is(err, errSkip):
				res.Skipped++
			default:
				res.Errors++
				log.Printf("importer: %s: %v", path, err)
			}
			return nil
		})
		if err != nil {
			return res, err
		}
	}
	return res, nil
}

func importOne(ctx context.Context, p Store, pm pathmap.Mapper, localPath, mime string) error {
	artist, title, album := readTags(localPath)
	if artist == "" || title == "" {
		a2, t2, ok := fromFilename(localPath)
		if !ok {
			return errSkip
		}
		if artist == "" {
			artist = a2
		}
		if title == "" {
			title = t2
		}
	}

	if v := quality.Screen(artist, title, ""); !v.OK {
		return errSkip
	}
	normKey := quality.NormalizedKey(artist, title)

	if kind, err := p.LegacyMarkKind(ctx, normKey); err == nil && kind == "blocked" {
		return errSkip
	}
	if existing, err := p.TrackByKey(ctx, normKey); err == nil && existing != nil {
		return errSkip
	}

	info, err := os.Stat(localPath)
	if err != nil {
		return err
	}

	tier := "unknown"
	if mime == "audio/flac" {
		tier = "lossless"
	}

	trackID := "t_" + randID()
	fileID := "f_" + randID()
	return p.InsertTrackWithFile(ctx,
		db.NewTrack{
			ID:            trackID,
			Artist:        artist,
			Title:         title,
			Album:         album,
			ReleaseKind:   quality.ReleaseKind(title, album),
			Explicit:      quality.IsExplicit(title),
			IsAltVersion:  quality.IsAltVersion(title),
			NormalizedKey: normKey,
		},
		db.NewTrackFile{
			ID:            fileID,
			NormalizedKey: normKey,
			FilePath:      pm.ToCanonical(localPath),
			MimeType:      mime,
			SizeBytes:     info.Size(),
			Source:        "legacy_import",
			QualityTier:   tier,
		},
	)
}

func readTags(path string) (artist, title, album string) {
	f, err := os.Open(path)
	if err != nil {
		return "", "", ""
	}
	defer f.Close()
	m, err := tag.ReadFrom(f)
	if err != nil {
		return "", "", ""
	}
	return sanitizeTag(m.Artist()), sanitizeTag(m.Title()), sanitizeTag(m.Album())
}

// sanitizeTag чинит теги из старых файлов: ID3v1 и часть ID3v2 в старой
// библиотеке хранят русский текст в Windows-1251 без пометки кодировки —
// dhowden/tag отдаёт эти байты как есть, и Postgres (UTF-8) на такое падает.
// Пробуем перекодировать как cp1251; не вышло — вырезаем некорректные байты,
// чтобы трек не потерялся совсем.
func sanitizeTag(s string) string {
	s = strings.TrimSpace(s)
	if s == "" || utf8.ValidString(s) {
		return s
	}
	if fixed, err := charmap.Windows1251.NewDecoder().String(s); err == nil && utf8.ValidString(fixed) {
		return strings.TrimSpace(fixed)
	}
	return strings.TrimSpace(strings.ToValidUTF8(s, ""))
}

// fromFilename разбирает «Артист - Название.ext» — самый частый вид имён в
// старой библиотеке, когда тегов нет или они пустые.
func fromFilename(path string) (artist, title string, ok bool) {
	base := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	parts := strings.SplitN(base, " - ", 2)
	if len(parts) != 2 {
		return "", "", false
	}
	a, t := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
	if a == "" || t == "" {
		return "", "", false
	}
	return a, t, true
}

// SweepResult — счётчики одного прогона Sweep.
type SweepResult struct {
	Checked int // всего треков в каталоге проверили
	Removed int // не прошли Screen ещё раз — убраны
	Errors  int // метку поставили, а файл в корзину переложить не вышло
}

// Sweep прогоняет уже существующий каталог через текущие правила Screen
// (нужно, например, когда список мусорных слов расширили и хочется почистить
// то, что попало в каталог раньше). Как и удаление с телефона — не стирает
// файл насовсем: переносит в _trash и метит blocked, чтобы не всплыл опять
// при повторном импорте/скачивании. Возвращает список того, что убрали —
// показать Alex, что именно посчиталось мусором.
func Sweep(ctx context.Context, p Store, pm pathmap.Mapper) (SweepResult, []db.SweepRow, error) {
	var res SweepResult
	if p == nil {
		return res, nil, errors.New("importer: нет базы")
	}
	rows, err := p.TracksForSweep(ctx)
	if err != nil {
		return res, nil, err
	}
	removed := make([]db.SweepRow, 0)
	for _, t := range rows {
		if ctx.Err() != nil {
			return res, removed, ctx.Err()
		}
		res.Checked++
		if v := quality.Screen(t.Artist, t.Title, ""); v.OK {
			continue
		}
		if err := p.UpsertLegacyMark(ctx, db.LegacyMark{Key: t.NormKey, Kind: "blocked", At: time.Now()}); err != nil {
			log.Printf("sweep %s: пометить blocked: %v", t.ID, err)
			res.Errors++
			continue
		}
		if err := pathmap.MoveToTrash(pm, pm.ToLocal(t.FilePath)); err != nil {
			log.Printf("sweep %s: файл в корзину (%s): %v", t.ID, t.FilePath, err)
			res.Errors++
		}
		res.Removed++
		removed = append(removed, t)
	}
	return res, removed, nil
}

func randID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
