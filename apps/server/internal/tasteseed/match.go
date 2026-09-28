// Package tasteseed — сопоставление внешнего списка песен (лайки Яндекса) с каталогом для начального
// вкуса своей копии плеера (cmd/soundflow/tasteseed.go).
package tasteseed

import (
	"soundflow/server/internal/coverfind"
	"soundflow/server/internal/localdb"
)

// Pair — песня внешнего списка.
type Pair struct{ Artist, Title string }

// Key — «главный исполнитель + суть названия»: Яндекс пишет соавторов через запятую, каталог — через
// «&»; «(Radio Edit)», «(feat. …)» и регистр не мешают.
func Key(artist, title string) string {
	lead := ""
	if a := coverfind.ArtistsOf(artist); len(a) > 0 {
		lead = a[0]
	}
	return lead + "__" + coverfind.TitleCore(title)
}

// Match — id песен каталога, которые есть во внешнем списке.
func Match(names []localdb.TrackName, pairs []Pair) []string {
	want := make(map[string]bool, len(pairs))
	for _, p := range pairs {
		want[Key(p.Artist, p.Title)] = true
	}
	var ids []string
	for _, t := range names {
		if want[Key(t.Artist, t.Title)] {
			ids = append(ids, t.ID)
		}
	}
	return ids
}
