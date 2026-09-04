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

	"github.com/dhowden/tag"

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
func Scan(ctx context.Context, p *db.Pool, pm pathmap.Mapper, roots []string) (Result, error) {
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

func importOne(ctx context.Context, p *db.Pool, pm pathmap.Mapper, localPath, mime string) error {
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
	return strings.TrimSpace(m.Artist()), strings.TrimSpace(m.Title()), strings.TrimSpace(m.Album())
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

func randID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
