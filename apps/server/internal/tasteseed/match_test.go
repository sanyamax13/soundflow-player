package tasteseed

import (
	"slices"
	"testing"

	"soundflow/server/internal/localdb"
)

func TestMatch(t *testing.T) {
	names := []localdb.TrackName{
		{ID: "t1", Artist: "Угол Зрения & Катя Чехова", Title: "Провайдер"},
		{ID: "t2", Artist: "Imagine Dragons", Title: "Bad Liar (Radio Edit)"},
		{ID: "t3", Artist: "Кино", Title: "Кукушка"},
		{ID: "t4", Artist: "Кино", Title: "Группа крови"},
	}
	pairs := []Pair{
		{Artist: "Угол Зрения, Катя Чехова", Title: "Провайдер"},
		{Artist: "imagine dragons", Title: "Bad Liar"},
		{Artist: "КИНО", Title: "Кукушка"},
		{Artist: "Звери", Title: "Танцуй"},
	}
	got := Match(names, pairs)
	slices.Sort(got)
	if !slices.Equal(got, []string{"t1", "t2", "t3"}) {
		t.Fatalf("совпали %v", got)
	}
}
