package api

import "testing"

func TestDeleteReason(t *testing.T) {
	cases := []struct {
		name    string
		payload []byte
		want    string
	}{
		{"пусто", nil, ""},
		{"нет поля reason", []byte(`{}`), ""},
		{"есть причина", []byte(`{"reason":"dislike"}`), "dislike"},
		{"битый json", []byte(`{not json`), ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := deleteReason(c.payload); got != c.want {
				t.Errorf("deleteReason(%s) = %q, ждал %q", c.payload, got, c.want)
			}
		})
	}
}
