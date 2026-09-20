package main

import (
	"fmt"
	"net/http"
	"os"
	"sort"
)

// «Не качать», а файл лежит на диске (Alex TG 20245/20249, 21.09.2026): у песни стоит метка «больше не качать»
// (дизлайк/убрано), но сама песня осталась в каталоге, потому что её файл лежит в папке-сборнике — скан 21.09 занёс
// так 236 песен из «Дискотека 2026 Vol. 231», «Русский хит…» и других. Alex: «если их не качать, то и всю инфу
// удалить, кроме как оставить "не качать"» и «сотри файлы».
//
// Стирание — необратимое, поэтому сама программа его не делает: окно показывает плашку «песни из "не качать"
// лежат на диске» со списком папок и кнопкой; по кнопке программа делает то же, что «Удалить навсегда» из меню
// окна (deleteForeverWith, ctxmenu.go): песня уходит из каталога и с телефонного плана, её файл стирается насовсем,
// пустые папки убираются, метка «не качать» остаётся; больше bigDeleteThreshold песен — перед этим копия базы.
// Копии той же песни в других папках здесь НЕ стираем (в списке окна их не видно): если копия есть, скан заново
// занесёт её в каталог, и плашка покажет её отдельно.
// Список для стирания сервер каждый раз собирает заново из базы и с диска (не из того, что прислало окно).

// blockedReport — песни из «не качать», у которых файл действительно лежит на диске.
type blockedReport struct {
	IDs     []string
	Bytes   int64
	Folders []folderCount // по убыванию, не больше 12
}

func (s *Service) findBlockedOnDisk() blockedReport {
	var rep blockedReport
	refs, err := s.db.BlockedTrackFiles()
	if err != nil {
		return rep
	}
	seen := map[string]bool{}
	perFolder := map[string]int{}
	for _, r := range refs {
		local := s.localPath(r.Path)
		fi, err := os.Stat(local)
		if err != nil || fi.IsDir() {
			continue // файла нет (им займётся сверка каталога с диском) или это не файл
		}
		rep.Bytes += fi.Size()
		if r.TrackID == "" || seen[r.TrackID] {
			continue
		}
		seen[r.TrackID] = true
		rep.IDs = append(rep.IDs, r.TrackID)
		perFolder[pathFolder(local)]++
	}
	for f, n := range perFolder {
		rep.Folders = append(rep.Folders, folderCount{Folder: f, Songs: n})
	}
	sort.Slice(rep.Folders, func(i, j int) bool {
		if rep.Folders[i].Songs != rep.Folders[j].Songs {
			return rep.Folders[i].Songs > rep.Folders[j].Songs
		}
		return rep.Folders[i].Folder < rep.Folders[j].Folder
	})
	if len(rep.Folders) > 12 {
		rep.Folders = rep.Folders[:12]
	}
	return rep
}

// GET /api/catalog/blocked-files — сколько песен из «не качать» лежит на диске (плашка в окне).
func (s *Service) hBlockedFiles(w http.ResponseWriter, r *http.Request) {
	rep := s.findBlockedOnDisk()
	folders := rep.Folders
	if folders == nil {
		folders = []folderCount{}
	}
	writeJSON(w, map[string]any{"songs": len(rep.IDs), "bytes": rep.Bytes, "folders": folders})
}

// POST /api/catalog/blocked-files/erase — Alex нажал «Стереть»: стереть насовсем файлы песен из «не качать»
// и убрать их из каталога (метка остаётся). Отвечает так же, как «Удалить навсегда» (deleteResult).
func (s *Service) hBlockedFilesErase(w http.ResponseWriter, r *http.Request) {
	if s.store == nil {
		http.Error(w, "сервис ещё поднимается, попробуй через пару секунд", 503)
		return
	}
	rep := s.findBlockedOnDisk()
	if len(rep.IDs) == 0 {
		writeJSON(w, deleteResult{})
		return
	}
	res, err := s.deleteForeverWith(r.Context(), rep.IDs, false)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	_ = s.db.AddServerLog("info", "", "", fmt.Sprintf("«не качать» → стёрто по кнопке в окне: песен %d, файлов %d", res.Deleted, res.FilesErased), res.Bytes)
	writeJSON(w, res)
}
