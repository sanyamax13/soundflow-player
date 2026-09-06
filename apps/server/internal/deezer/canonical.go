package deezer

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
)

// CanonInfo — «эталонная» (студийная альбомная) версия трека по данным Deezer.
type CanonInfo struct {
	Found       bool
	Title       string
	DurationSec int
	Album       string
}

type canonResponse struct {
	Data []struct {
		Title        string `json:"title"`
		TitleVersion string `json:"title_version"`
		Duration     int    `json:"duration"`
		Artist       struct {
			Name string `json:"name"`
		} `json:"artist"`
		Album struct {
			Title string `json:"title"`
		} `json:"album"`
	} `json:"data"`
}

// CanonicalTrack ищет студийную альбомную версию трека: первый результат
// поиска Deezer с пустым title_version и подходящим исполнителем. Deezer
// сортирует по релевантности — оригинальная альбомная запись почти всегда
// первая, а кавер/ремикс/акустика несут пометку в title_version.
//
// Нужна как надёжный источник длительности при перекачке по причине «не та
// версия» (пункт 5 разбора плеера, Alex TG 18508): MusicBrainz заблокирован
// и с brain, и с fg (проверено 05.09 и 07.09.2026), Deezer — открытый API
// без ключа и достижим. Found=false — у Deezer нет чистой версии для этого
// исполнителя (тогда честно «нормальной версии не существует»).
func CanonicalTrack(ctx context.Context, artist, title string) (CanonInfo, error) {
	q := url.Values{"q": {artist + " " + title}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"?"+q.Encode(), nil)
	if err != nil {
		return CanonInfo{}, err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return CanonInfo{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return CanonInfo{}, nil // троттлинг/сбой — «не нашли», не ошибка
	}
	var out canonResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return CanonInfo{}, err
	}
	want := norm(artist)
	for _, d := range out.Data {
		if strings.TrimSpace(d.TitleVersion) != "" {
			continue // (Acoustic), (Live), (Cover of ...) и т.п.
		}
		if d.Duration <= 0 {
			continue
		}
		got := norm(d.Artist.Name)
		if want != "" && got != "" && !strings.Contains(got, want) && !strings.Contains(want, got) {
			continue // другой исполнитель (напр. кавер-бэнд)
		}
		return CanonInfo{Found: true, Title: d.Title, DurationSec: d.Duration, Album: d.Album.Title}, nil
	}
	return CanonInfo{}, nil
}

// norm — грубая нормализация имени для нестрогого сравнения исполнителя:
// нижний регистр, только буквы/цифры (латиница + кириллица).
func norm(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r >= 'а' && r <= 'я', r == 'ё':
			b.WriteRune(r)
		}
	}
	return b.String()
}
