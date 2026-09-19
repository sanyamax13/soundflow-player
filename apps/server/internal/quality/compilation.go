package quality

import (
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Сборники без тегов «альбом» (Alex TG 19970, 19.09.2026): рип старым
// инструментом кладёт песни в папку «01. …», «02. …», а внутри файлов ни
// исполнителя, ни альбома. Без альбома каждая песня в каталоге — своя плитка-
// «сингл». Правило: папка, где имена файлов идут с номерами по порядку, — это
// один сборник, и альбомом песен без тега становится имя папки.

var (
	// номер в начале имени файла: «01. Artist», «01 Artist», «01_Artist», «1.Artist».
	compNumPrefix = regexp.MustCompile(`^\s*(\d{1,3})\s*[-._) ]\s*\S`)

	// имя папки — заглушка, а не название: «CD 1», «Disc2», «Диск 1»,
	// «Album Artist - Album cd1» (так называет папки тегировщик, которому не
	// дали заполнить шаблон).
	compFolderGeneric = regexp.MustCompile(`(?i)^\s*(?:(?:cd|disc|disk|диск)[\s._-]*\d+\b.*|album artist\s*-\s*album\b.*)$`)

	// хвосты в скобках: «[FLAC Rip]», «(2CD, 2015)», «[320]».
	compBrackets = regexp.MustCompile(`\s*[\[\(][^\]\)]*[\]\)]`)
)

// LooksLikeNumberedAlbum — по именам аудиофайлов ОДНОЙ папки: это сборник/альбом
// с пронумерованными песнями? Нужно ≥3 файла, у ≥80% номер в начале имени и
// ≥3 РАЗНЫХ номера. Последнее отсекает папку исполнителя вроде «25_17»: у всех
// файлов «25_17 - …» в начале одно и то же — это название группы, не номер.
func LooksLikeNumberedAlbum(fileNames []string) bool {
	if len(fileNames) < 3 {
		return false
	}
	numbered := 0
	distinct := map[int]bool{}
	for _, n := range fileNames {
		if m := compNumPrefix.FindStringSubmatch(n); m != nil {
			numbered++
			v, _ := strconv.Atoi(m[1])
			distinct[v] = true
		}
	}
	return numbered*10 >= len(fileNames)*8 && len(distinct) >= 3
}

// AlbumFromFolder — имя альбома-сборника по пути к папке: без хвостов в скобках
// («Hitzone 72 (2CD, 2015) [FLAC Rip]» → «Hitzone 72»); если сама папка — заглушка
// («CD 1», «Album Artist - Album cd1»), берём папку уровнем выше. Пусто —
// подходящего имени нет (тогда песни остаются как были).
func AlbumFromFolder(dir string) string {
	name := filepath.Base(dir)
	if compFolderGeneric.MatchString(name) {
		if parent := filepath.Dir(dir); parent != dir {
			name = filepath.Base(parent)
		}
	}
	name = CleanTag(folderLabel(name), false)
	if name == "" || compFolderGeneric.MatchString(name) || name == "." || name == string(filepath.Separator) {
		return ""
	}
	return name
}

// folderLabel убирает из имени папки скобочные хвосты; если после этого пусто
// (папка называется целиком в скобках) — оставляет как было.
func folderLabel(s string) string {
	t := strings.TrimSpace(compBrackets.ReplaceAllString(s, ""))
	t = tagMultiSpace.ReplaceAllString(t, " ")
	if t == "" {
		return strings.TrimSpace(s)
	}
	return t
}
