package coverfind

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFold(t *testing.T) {
	for in, want := range map[string]string{
		"Ёлка":    "елка",
		"Би-2":    "би2",
		"AC/DC":   "acdc",
		"Beyoncé": "beyonce",
		"  ЛСП! ": "лсп",
	} {
		if got := Fold(in); got != want {
			t.Errorf("Fold(%q) = %q, ждали %q", in, got, want)
		}
	}
}

func TestArtistOK(t *testing.T) {
	cases := []struct {
		want string
		cand []string
		ok   bool
		why  string
	}{
		{"Кино", []string{"Кино"}, true, "то же имя"},
		{"Depeche Mode", []string{"Depeche Mode"}, true, "латиница"},
		{"Ленинград", []string{"Ленинград", "Шнур"}, true, "среди нескольких"},
		// главный исполнитель — первый; гость в «feat.» не считается
		{"A Great Big World ft. Christina Aguilera", []string{"Christina Aguilera"}, false, "только гость совпал"},
		{"A Great Big World ft. Christina Aguilera", []string{"A Great Big World", "Christina Aguilera"}, true, "главный есть"},
		{"Кино", []string{"Кинчев"}, false, "похожее, но другой"},
		{"Metallica", []string{"Metalica"}, true, "опечатка в длинном имени"},
		{"ЛСП", []string{"Слава КПСС"}, false, "короткое имя — только точное совпадение"},
		{"Макс Корж & Друзья", []string{"Макс Корж"}, true, "«&» — разделитель"},
	}
	for _, c := range cases {
		if got := ArtistOK(c.want, c.cand); got != c.ok {
			t.Errorf("ArtistOK(%q, %v) = %v, ждали %v (%s)", c.want, c.cand, got, c.ok, c.why)
		}
	}
}

func TestTitleOK(t *testing.T) {
	cases := []struct {
		want, cand string
		ok         bool
	}{
		{"Группа крови", "Группа крови (Remastered 2011)", true},
		{"Personal Jesus", "Personal Jesus - Radio Edit", true},
		{"Enjoy the Silence", "Enjoy the Silence [Live]", true},
		{"Звезда по имени Солнце", "Звезда по имени Солнце", true},
		{"Группа крови", "Кукушка", false},
		{"Intro", "Outro", false},
	}
	for _, c := range cases {
		if got := TitleOK(c.want, c.cand); got != c.ok {
			t.Errorf("TitleOK(%q, %q) = %v, ждали %v", c.want, c.cand, got, c.ok)
		}
	}
}

// Число как у difflib.SequenceMatcher.ratio() (сверено на Python).
func TestRatio(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want float64
	}{
		{"abcd", "bcde", 0.75},
		{"", "", 1},
		{"abc", "", 0},
		{"кино", "кино", 1},
		{"metallica", "metalica", 2 * 8.0 / 17},
	} {
		if got := Ratio(c.a, c.b); got < c.want-1e-9 || got > c.want+1e-9 {
			t.Errorf("Ratio(%q,%q) = %v, ждали %v", c.a, c.b, got, c.want)
		}
	}
}

// noisy — картинка w×h с рисунком (чтобы файл не был крошечным).
func noisy(w, h int) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{uint8(x * 7), uint8(y * 5), uint8((x * y) % 251), 255})
		}
	}
	return img
}

func jpegBytes(t *testing.T, w, h int) []byte {
	t.Helper()
	var b bytes.Buffer
	if err := jpeg.Encode(&b, noisy(w, h), &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestPrepareJPEGShrinksBigAndKeepsSmall(t *testing.T) {
	big, err := PrepareJPEG(jpegBytes(t, 1000, 800), 600)
	if err != nil {
		t.Fatal(err)
	}
	img, _, err := image.Decode(bytes.NewReader(big))
	if err != nil {
		t.Fatal(err)
	}
	if b := img.Bounds(); b.Dx() != 600 || b.Dy() != 480 {
		t.Errorf("ждали 600×480, получили %dx%d", b.Dx(), b.Dy())
	}

	small := jpegBytes(t, 400, 400)
	same, err := PrepareJPEG(small, 600)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(same, small) {
		t.Errorf("подходящий JPEG не должен перекодироваться")
	}

	var pb bytes.Buffer
	_ = png.Encode(&pb, noisy(900, 900))
	fromPNG, err := PrepareJPEG(pb.Bytes(), 600)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(fromPNG, []byte{0xff, 0xd8, 0xff}) {
		t.Errorf("PNG должен стать JPEG")
	}
}

func TestPrepareJPEGRejectsJunk(t *testing.T) {
	if _, err := PrepareJPEG([]byte("<html>not an image</html>"), 600); err == nil {
		t.Errorf("текст — не обложка")
	}
	if _, err := PrepareJPEG(bytes.Repeat([]byte("x"), 6000), 600); err == nil {
		t.Errorf("мусор нужного размера — не обложка")
	}
	tiny := jpegBytes(t, 40, 40)
	if _, err := PrepareJPEG(tiny, 600); err == nil {
		t.Errorf("картинка меньше 100 px — не обложка")
	}
}

// Deezer отдаёт чужого исполнителя — отбрасываем; iTunes — своего — берём.
func TestFinderTakesOnlyVerifiedCandidate(t *testing.T) {
	img := jpegBytes(t, 700, 700)
	mux := http.NewServeMux()
	mux.HandleFunc("/deezer/search", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"data":[{"title":"Группа крови","artist":{"name":"Кавер-бэнд"},"album":{"title":"Хиты","cover_xl":"%s/img.jpg"}}]}`, "http://"+r.Host)
	})
	mux.HandleFunc("/itunes/search", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"results": []map[string]any{
			{"artistName": "Кино", "trackName": "Группа крови (Remastered)", "collectionName": "Группа крови",
				"artworkUrl100": "http://" + r.Host + "/img100x100bb.jpg"},
		}})
	})
	mux.HandleFunc("/img100x100bb.jpg", func(w http.ResponseWriter, r *http.Request) { t.Errorf("должны просить 600x600bb") })
	mux.HandleFunc("/img600x600bb.jpg", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(img) })
	mux.HandleFunc("/img.jpg", func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("картинку чужого исполнителя качать не надо")
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	web := &Web{HTTP: srv.Client(), DeezerURL: srv.URL + "/deezer", ITunesURL: srv.URL + "/itunes"}
	f := &Finder{Sources: []Source{
		{Name: "deezer", Search: web.deezer},
		{Name: "itunes", Search: web.itunes},
	}}
	res, err := f.Find(context.Background(), "Кино", "Группа крови")
	if err != nil {
		t.Fatal(err)
	}
	if res == nil || res.Source != "itunes" || len(res.JPEG) == 0 {
		t.Fatalf("ждали обложку из itunes, получили %+v", res)
	}
	im, _, _ := image.Decode(bytes.NewReader(res.JPEG))
	if im == nil || im.Bounds().Dx() != 600 {
		t.Errorf("картинка должна быть уменьшена до 600 px")
	}
}

func TestFinderNothingFoundIsNil(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/deezer/search", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(`{"data":[]}`)) })
	srv := httptest.NewServer(mux)
	defer srv.Close()
	web := &Web{HTTP: srv.Client(), DeezerURL: srv.URL + "/deezer"}
	f := &Finder{Sources: []Source{{Name: "deezer", Search: web.deezer}}}
	res, err := f.Find(context.Background(), "Никто", "Ничего")
	if err != nil || res != nil {
		t.Errorf("ждали nil, nil; получили %+v, %v", res, err)
	}
}

// Все источники молчат (нет интернета) — это не «обложки нет»: вызывающий не должен
// помечать песню как «не нашлась».
func TestFinderAllSourcesDownIsOffline(t *testing.T) {
	down := func(ctx context.Context, artist, title string) ([]Candidate, error) {
		return nil, fmt.Errorf("нет сети")
	}
	f := &Finder{Sources: []Source{{Name: "a", Search: down}, {Name: "b", Search: down}}}
	res, err := f.Find(context.Background(), "Кино", "Группа крови")
	if res != nil || err != ErrOffline {
		t.Errorf("ждали ErrOffline, получили %+v, %v", res, err)
	}
	// один источник ответил пустым — это уже честное «не нашлось»
	empty := func(ctx context.Context, artist, title string) ([]Candidate, error) { return nil, nil }
	f = &Finder{Sources: []Source{{Name: "a", Search: down}, {Name: "b", Search: empty}}}
	if res, err := f.Find(context.Background(), "Кино", "Группа крови"); res != nil || err != nil {
		t.Errorf("ждали nil, nil; получили %+v, %v", res, err)
	}
}

// 27.09.2026: имена из сборников ремиксов — «Гр. «…»», «ВИА», инициалы, «(Ремикс DJ …)».
func TestSearchNames(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Гр. «Отпетые мошенники»", "Отпетые мошенники"},
		{"ВИА «Гра» (Н. Грановская, А. Джанабаева, В. Брежнева)", "ВИА Гра"},
		{"Д. Билан", "Билан"},
		{"В.  Левкин и Гульназ", "Левкин и Гульназ"},
		{"Группа Фристайл", "Фристайл"},
		{"Нюша", "Нюша"},
		{"A.R.T.", "A.R.T."},
	}
	for _, c := range cases {
		if got := SearchArtist(c.in); got != c.want {
			t.Errorf("SearchArtist(%q) = %q, ждал %q", c.in, got, c.want)
		}
	}
	if got := SearchTitle("Мани-мани (Ремикс DJ Сканер)"); got != "Мани-мани" {
		t.Errorf("SearchTitle = %q", got)
	}
	if got := SearchTitle("Больно (Dj Vengerov Remix)"); got != "Больно" {
		t.Errorf("SearchTitle = %q", got)
	}
}
