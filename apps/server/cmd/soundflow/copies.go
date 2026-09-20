package main

import (
	"context"
	"encoding/json"
	"io/fs"
	"net/http"
	"path/filepath"
	"strings"

	"soundflow/server/internal/cuesplit"
	"soundflow/server/internal/quality"
)

// «Копии песни» (ревизия 20.09.2026, п. 1а; Alex TG 20177, вариант 2: «удалять
// песню целиком, со всеми копиями»).
//
// В каталоге на песню (ключ «исполнитель + название») одна строка. Остальные
// файлы с теми же исполнителем и названием лежат на диске в других папках
// (сборники, повторные закачки) — скан пропускает их как повторы, поэтому в
// каталоге их нет. Раньше «удалить навсегда» убирало из каталога песню и
// переносило в корзину один файл; копии оставались на диске невидимыми и при
// сбросе метки могли вернуться. Теперь копии уходят вместе с песней — так же, в
// корзину _deleted (не стираются).

// findCopyFiles — для каждого ключа из want (ключ → путь основного файла в
// каталоге; пусто, если файла нет) найти в папке-источнике ДРУГИЕ файлы с тем же
// ключом (теги читаются тем же resolveTags, что и в скане, значит ключ совпадает
// с тем, как скан решает «это повтор»). Основные файлы, cue-альбомы и корзина
// _deleted пропускаются. Папка-источник не задана — копий «нет».
func (s *Service) findCopyFiles(ctx context.Context, want map[string]string) map[string][]string {
	out := map[string][]string{}
	if len(want) == 0 {
		return out
	}
	canon := map[string]bool{}
	for _, p := range want {
		if p != "" {
			canon[strings.ToLower(filepath.Clean(p))] = true
		}
	}
	for _, root := range s.libraryRoots() {
		_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				return nil
			}
			if d.IsDir() {
				if skipScanDir(d.Name()) {
					return fs.SkipDir
				}
				return nil
			}
			if _, isAudio := audioExt[strings.ToLower(filepath.Ext(path))]; !isAudio {
				return nil
			}
			if canon[strings.ToLower(filepath.Clean(path))] {
				return nil
			}
			if _, _, isCue := cuesplit.FindFor(path); isCue {
				return nil
			}
			ar, ti, _ := resolveTags(path)
			if ar == "" || ti == "" {
				return nil
			}
			key := quality.NormalizedKey(ar, ti)
			if _, ok := want[key]; ok {
				out[key] = append(out[key], path)
			}
			return nil
		})
	}
	return out
}

// copiesWanted — ключи и основные файлы песен с указанными id (для findCopyFiles).
func (s *Service) copiesWanted(ctx context.Context, ids []string) map[string]string {
	want := map[string]string{}
	for _, id := range ids {
		normKey, canonical, ok, err := s.store.TrackForDeletion(ctx, id)
		if err != nil || !ok {
			continue
		}
		want[normKey] = s.localPath(canonical)
	}
	return want
}

// POST /api/tracks/copies  body {"ids":[…]}  →  {"copies":N,"songs":M}
//
// Сколько ещё файлов-копий лежит на диске у этих песен и у скольких песен они
// есть. Окно спрашивает ПЕРЕД подтверждением «Удалить навсегда» и пишет:
// «У этих песен есть ещё N копий — уберу и их». Ничего не меняет.
func (s *Service) hTrackCopies(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "нужно тело {ids:[…]}", 400)
		return
	}
	if s.store == nil {
		http.Error(w, "сервис ещё поднимается, попробуй через пару секунд", 503)
		return
	}
	found := s.findCopyFiles(r.Context(), s.copiesWanted(r.Context(), body.IDs))
	files := 0
	for _, list := range found {
		files += len(list)
	}
	writeJSON(w, map[string]any{"copies": files, "songs": len(found)})
}
