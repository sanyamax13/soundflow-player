package coverfind

import "context"

// YandexAlbum / YandexItem — то, что качалка (Python, Яндекс.Музыка) отдаёт про
// найденные треки: исполнители, название, обложка трека и обложки его альбомов.
// Проверку «тот ли это трек» и выбор альбома делаем здесь, в Go: качалка остаётся
// тонкой (только доступ к Яндексу по токену).
type YandexAlbum struct {
	Title       string   `json:"title"`
	Artists     []string `json:"artists"`
	Compilation bool     `json:"compilation"`
	CoverURL    string   `json:"cover_url"`
}

type YandexItem struct {
	Artists  []string      `json:"artists"`
	Title    string        `json:"title"`
	CoverURL string        `json:"cover_url"`
	Albums   []YandexAlbum `json:"albums"`
}

// YandexSource — источник для Finder поверх функции, которая спрашивает качалку.
// Для каждого трека берём обложку «своего» альбома: сначала альбом исполнителя, не
// сборник; потом любой альбом исполнителя; потом любой не сборник; потом что есть
// (сборник «Хиты 90-х» вместо альбома — худший вариант, но лучше пустоты).
func YandexSource(fetch func(ctx context.Context, artist, title string) ([]YandexItem, error)) func(ctx context.Context, artist, title string) ([]Candidate, error) {
	return func(ctx context.Context, artist, title string) ([]Candidate, error) {
		items, err := fetch(ctx, artist, title)
		if err != nil {
			return nil, err
		}
		var out []Candidate
		for _, it := range items {
			img, album := it.CoverURL, ""
			best := 9
			for _, a := range it.Albums {
				if a.CoverURL == "" {
					continue
				}
				own := ArtistOK(artist, a.Artists)
				rank := 3
				switch {
				case own && !a.Compilation:
					rank = 0
				case own:
					rank = 1
				case !a.Compilation:
					rank = 2
				}
				if rank < best {
					best, img, album = rank, a.CoverURL, a.Title
				}
			}
			out = append(out, Candidate{Artists: it.Artists, Title: it.Title, Image: img, Album: album})
		}
		return out, nil
	}
}
