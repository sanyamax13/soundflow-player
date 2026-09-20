package coverfind

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Candidate — один вариант из ответа источника: кто поёт, как называется, где
// лежит картинка. Годность (тот ли это трек) решает Finder по ArtistOK/TitleOK.
type Candidate struct {
	Artists []string
	Title   string
	Image   string
	Album   string
}

// Source — источник обложек. Gap — минимальная пауза между запросами к нему
// (бесплатные API режут частые запросы).
type Source struct {
	Name   string
	Gap    time.Duration
	Search func(ctx context.Context, artist, title string) ([]Candidate, error)
}

// Result — найденная и проверенная обложка (уже JPEG ≤ MaxPx).
type Result struct {
	Source     string
	ImageURL   string
	CandArtist string
	CandTitle  string
	JPEG       []byte
}

// Finder ищет обложку по источникам по порядку; первая проверенная картинка
// побеждает.
type Finder struct {
	Sources []Source
	HTTP    *http.Client
	MaxPx   int // по умолчанию 600

	mu   sync.Mutex
	last map[string]time.Time
}

// ErrOffline — ни один источник не ответил (нет интернета, все режут): это НЕ значит «обложки
// нет», поэтому вызывающий не должен помечать песню как «не нашлась».
var ErrOffline = errors.New("ни один источник обложек не ответил")

// Find — nil, nil означает «источники ответили, но подходящей обложки нет»; ErrOffline — ответа
// не было ни от одного.
func (f *Finder) Find(ctx context.Context, artist, title string) (*Result, error) {
	q := LeadArtist(artist)
	answered := 0
	for _, src := range f.Sources {
		if err := f.throttle(ctx, src.Name, src.Gap); err != nil {
			return nil, err
		}
		cands, err := src.Search(ctx, q, title)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			continue // источник молчит — идём к следующему
		}
		answered++
		for _, c := range cands {
			if c.Image == "" || !ArtistOK(artist, c.Artists) || !TitleOK(title, c.Title) {
				continue
			}
			img, err := f.fetchImage(ctx, c.Image)
			if err != nil {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				continue
			}
			return &Result{
				Source: src.Name, ImageURL: c.Image,
				CandArtist: strings.Join(c.Artists, ", "), CandTitle: c.Title, JPEG: img,
			}, nil
		}
	}
	if len(f.Sources) > 0 && answered == 0 {
		return nil, ErrOffline
	}
	return nil, nil
}

func (f *Finder) throttle(ctx context.Context, name string, gap time.Duration) error {
	if gap <= 0 {
		return ctx.Err()
	}
	f.mu.Lock()
	if f.last == nil {
		f.last = map[string]time.Time{}
	}
	now := time.Now()
	at := f.last[name].Add(gap)
	if at.Before(now) {
		at = now
	}
	f.last[name] = at
	f.mu.Unlock()
	if wait := time.Until(at); wait > 0 {
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return ctx.Err()
}

func (f *Finder) client() *http.Client {
	if f.HTTP != nil {
		return f.HTTP
	}
	return &http.Client{Timeout: 25 * time.Second}
}

func (f *Finder) fetchImage(ctx context.Context, u string) ([]byte, error) {
	body, err := getBody(ctx, f.client(), u)
	if err != nil {
		return nil, err
	}
	px := f.MaxPx
	if px <= 0 {
		px = 600
	}
	return PrepareJPEG(body, px)
}

// userAgent — MusicBrainz и другие просят представиться.
const userAgent = "SoundFlow-cover-finder/1.0 (personal music library)"

// getBody — GET с двумя попытками: при 429/503 ждём и пробуем ещё раз.
func getBody(ctx context.Context, c *http.Client, u string) ([]byte, error) {
	var lastErr error
	for try := 0; try < 2; try++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("User-Agent", userAgent)
		resp, err := c.Do(req)
		if err != nil {
			lastErr = err
			if !sleepCtx(ctx, time.Second) {
				return nil, ctx.Err()
			}
			continue
		}
		body, rerr := io.ReadAll(io.LimitReader(resp.Body, 12<<20))
		resp.Body.Close()
		if resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode == http.StatusServiceUnavailable {
			lastErr = fmt.Errorf("%s: %d", u, resp.StatusCode)
			if !sleepCtx(ctx, time.Duration(4+4*try)*time.Second) {
				return nil, ctx.Err()
			}
			continue
		}
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("%s: %d", u, resp.StatusCode)
		}
		if rerr != nil {
			return nil, rerr
		}
		return body, nil
	}
	return nil, lastErr
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	select {
	case <-time.After(d):
		return true
	case <-ctx.Done():
		return false
	}
}

func getJSON(ctx context.Context, c *http.Client, u string, out any) error {
	body, err := getBody(ctx, c, u)
	if err != nil {
		return err
	}
	return json.Unmarshal(body, out)
}

// Web — бесплатные источники без ключей. Адреса вынесены в поля, чтобы тесты
// подставляли свой сервер.
type Web struct {
	HTTP        *http.Client
	DeezerURL   string
	ITunesURL   string
	AudioDBURL  string
	MusicBrainz string
	CoverArt    string
}

// NewWeb — настоящие адреса.
func NewWeb() *Web {
	return &Web{
		HTTP:        &http.Client{Timeout: 25 * time.Second},
		DeezerURL:   "https://api.deezer.com",
		ITunesURL:   "https://itunes.apple.com",
		AudioDBURL:  "https://www.theaudiodb.com",
		MusicBrainz: "https://musicbrainz.org",
		CoverArt:    "https://coverartarchive.org",
	}
}

// Sources — Яндекс (если передан), Deezer, iTunes, AudioDB, MusicBrainz — в порядке,
// проверенном на 3 530 песнях: Яндекс лучше всех знает русскую музыку, остальные
// закрывают западную.
func (w *Web) Sources(yandex func(ctx context.Context, artist, title string) ([]Candidate, error)) []Source {
	var out []Source
	if yandex != nil {
		out = append(out, Source{Name: "yandex", Gap: 350 * time.Millisecond, Search: yandex})
	}
	return append(out,
		Source{Name: "deezer", Gap: 250 * time.Millisecond, Search: w.deezer},
		Source{Name: "itunes", Gap: 3200 * time.Millisecond, Search: w.itunes},
		Source{Name: "audiodb", Gap: 600 * time.Millisecond, Search: w.audiodb},
		Source{Name: "musicbrainz", Gap: 1100 * time.Millisecond, Search: w.musicbrainz},
	)
}

func (w *Web) deezer(ctx context.Context, artist, title string) ([]Candidate, error) {
	var out []Candidate
	for _, q := range []string{fmt.Sprintf(`artist:"%s" track:"%s"`, artist, title), artist + " " + title} {
		var j struct {
			Data []struct {
				Title  string `json:"title"`
				Artist struct {
					Name string `json:"name"`
				} `json:"artist"`
				Album struct {
					Title    string `json:"title"`
					CoverXL  string `json:"cover_xl"`
					CoverBig string `json:"cover_big"`
				} `json:"album"`
			} `json:"data"`
		}
		if err := getJSON(ctx, w.HTTP, w.DeezerURL+"/search?limit=6&q="+url.QueryEscape(q), &j); err != nil {
			return out, err
		}
		for _, d := range j.Data {
			img := d.Album.CoverXL
			if img == "" {
				img = d.Album.CoverBig
			}
			out = append(out, Candidate{Artists: []string{d.Artist.Name}, Title: d.Title, Image: img, Album: d.Album.Title})
		}
		if len(out) > 0 {
			break
		}
	}
	return out, nil
}

func (w *Web) itunes(ctx context.Context, artist, title string) ([]Candidate, error) {
	var j struct {
		Results []struct {
			ArtistName     string `json:"artistName"`
			TrackName      string `json:"trackName"`
			ArtworkURL100  string `json:"artworkUrl100"`
			CollectionName string `json:"collectionName"`
		} `json:"results"`
	}
	if err := getJSON(ctx, w.HTTP, w.ITunesURL+"/search?media=music&entity=song&limit=6&term="+url.QueryEscape(artist+" "+title), &j); err != nil {
		return nil, err
	}
	var out []Candidate
	for _, d := range j.Results {
		out = append(out, Candidate{
			Artists: []string{d.ArtistName}, Title: d.TrackName,
			Image: strings.Replace(d.ArtworkURL100, "100x100bb", "600x600bb", 1), Album: d.CollectionName,
		})
	}
	return out, nil
}

func (w *Web) audiodb(ctx context.Context, artist, title string) ([]Candidate, error) {
	var j struct {
		Track []struct {
			Artist string `json:"strArtist"`
			Track  string `json:"strTrack"`
			Thumb  string `json:"strTrackThumb"`
			Album  string `json:"strAlbum"`
		} `json:"track"`
	}
	if err := getJSON(ctx, w.HTTP, w.AudioDBURL+"/api/v1/json/2/searchtrack.php?s="+url.QueryEscape(artist)+"&t="+url.QueryEscape(title), &j); err != nil {
		return nil, err
	}
	var out []Candidate
	for _, d := range j.Track {
		out = append(out, Candidate{Artists: []string{d.Artist}, Title: d.Track, Image: d.Thumb, Album: d.Album})
	}
	return out, nil
}

func (w *Web) musicbrainz(ctx context.Context, artist, title string) ([]Candidate, error) {
	q := fmt.Sprintf(`recording:"%s" AND artist:"%s"`, strings.ReplaceAll(title, `"`, " "), strings.ReplaceAll(artist, `"`, " "))
	var j struct {
		Recordings []struct {
			Title        string `json:"title"`
			ArtistCredit []struct {
				Name   string `json:"name"`
				Artist struct {
					Name string `json:"name"`
				} `json:"artist"`
			} `json:"artist-credit"`
			Releases []struct {
				ID    string `json:"id"`
				Title string `json:"title"`
			} `json:"releases"`
		} `json:"recordings"`
	}
	if err := getJSON(ctx, w.HTTP, w.MusicBrainz+"/ws/2/recording/?fmt=json&limit=4&query="+url.QueryEscape(q), &j); err != nil {
		return nil, err
	}
	var out []Candidate
	for _, rec := range j.Recordings {
		var names []string
		for _, ac := range rec.ArtistCredit {
			n := ac.Name
			if n == "" {
				n = ac.Artist.Name
			}
			names = append(names, n)
		}
		for i, rel := range rec.Releases {
			if i >= 3 {
				break
			}
			out = append(out, Candidate{
				Artists: names, Title: rec.Title,
				Image: w.CoverArt + "/release/" + rel.ID + "/front-500", Album: rel.Title,
			})
		}
	}
	return out, nil
}
