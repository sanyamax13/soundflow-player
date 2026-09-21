package main

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"soundflow/server/internal/localdb"
)

func logRow(kind, artist, title, detail string) localdb.ServerLogRow {
	return localdb.ServerLogRow{At: time.Date(2026, 9, 21, 10, 0, 0, 0, time.UTC), Kind: kind, Artist: artist, Title: title, Detail: detail}
}

func TestHumanizeRowReadsLikeAPerson(t *testing.T) {
	cases := []struct {
		row              localdb.ServerLogRow
		icon, text, note string // text "" — запись не для человека
	}{
		{logRow("added", "Ghost", "Mary On A Cross", "скачано (yandex)"), "ok", "Скачано: Ghost — Mary On A Cross", "yandex"},
		{logRow("not_found", "Sleep Token", "Chokehold", "нормальной версии не нашлось"), "warn", "Не нашлось: Sleep Token — Chokehold", "нормальной версии не нашлось"},
		{logRow("error", "Hybrid Theory", "Go Loco", "не найдено"), "warn", "Не нашлось: Hybrid Theory — Go Loco", ""},
		{logRow("error", "телефон 66d0ed0b2c", "вылет приложения", "2026-09-18T07:20:18\nслой: flutter\nSocketException"), "warn", "На телефоне вылетело приложение", "подробности — в журнале (Настройки)"},
		{logRow("error", "Аквариум", "Город золотой", `сайдкар: Post "http://127.0.0.1:8001/find-audio": dial tcp`), "warn", "Качалка не ответила: Аквариум — Город золотой", "программа запущена не полностью?"},
		{logRow("error", "", "", "что-то сломалось\n#0 стек\n#1 стек"), "warn", "Ошибка: что-то сломалось", ""},
		{logRow("replaced", "ZIVERT", "ЯТЛ", ""), "ok", "Заменена на версию получше: ZIVERT — ЯТЛ", ""},
		{logRow("removed", "ZIVERT", "ЯТЛ", "плохая версия — ищу замену"), "info", "Плохая версия убрана, ищу замену: ZIVERT — ЯТЛ", ""},
		{logRow("info", "", "", "скан завершён: добавлено 31, пропущено 1364, ошибок 0"), "ok", "Скан папки: добавлено 31 песня", ""},
		{logRow("info", "", "", "скан завершён: добавлено 2, пропущено 10, ошибок 3"), "warn", "Скан папки: добавлено 2 песни, с ошибками — 3", ""},
		{logRow("info", "", "", "из меню окна: в план телефона +0 −92 (всего в плане +5 −1566)"), "info", "В план для телефона: убрать 92 песни", ""},
		{logRow("info", "", "", "план синхронизации сохранён: +12 −3"), "info", "В план для телефона: добавить 12 песен, убрать 3 песни", ""},
		{logRow("info", "", "", "план телефона отменён из окна (было +12 −3)"), "info", "План для телефона отменён", ""},
		{logRow("info", "", "", "удалено навсегда из окна: 3 песен (файлов стёрто 3, копий стёрто 0)"), "info", "Стёрто из окна: 3 песни", ""},
		{logRow("info", "", "", "каталог сверен с диском (сама): убрано песен 14, записей файлов 17 — файлов на диске нет"), "ok", "Каталог сверен с диском: убрано 14 песен", "файлов этих песен на диске нет"},
		{logRow("info", "", "", "волна на сегодня собрана сама: 26 песен"), "ok", "«Волна» на сегодня собрана: 26 песен", ""},
		{logRow("info", "", "", "обложки: проверено 506 — уже были 425 (в файле 383), нашла в интернете 72, не нашла 9"), "ok", "Обложки: найдено 72", ""},
		{logRow("info", "", "", "пересчёт завершён: посчитано 96, ошибок 1; первая причина: волна: ffmpeg"), "warn", "Отпечатки песен: посчитано 96, не вышло 1", ""},
		{logRow("info", "", "", "возврат песен с телефона (heard): без файла на диске 140"), "info", "Возврат песен с телефона на компьютер поставлен в очередь", ""},
		{logRow("info", "", "", `SoundFlow запущен (E:\soundflow-data\soundflow.db), модель: есть`), "info", "Программа запущена", ""},
		// шум: в ленту не попадает
		{logRow("info", "Duran Duran", "What Happens Tomorrow", "поиск и скачивание запущены"), "", "", ""},
		{logRow("info", "", "", "скан папки: G:\\музыка"), "", "", ""},
		{logRow("info", "", "", "скан завершён: добавлено 0, пропущено 1548, ошибок 0"), "", "", ""},
		{logRow("info", "Drummatix", "В Дали", "уже в каталоге"), "", "", ""},
		{logRow("info", "", "", "телефонный API слушает 0.0.0.0:8091"), "", "", ""},
		{logRow("info", "Угол Зрения", "Провайдер", "отпечаток не посчитан: ffmpeg: exec"), "", "", ""},
		{logRow("info", "", "", "обложки: проверено 68 — уже были 67, нашла в интернете 0, не нашла 0"), "", "", ""},
		{logRow("removed", "Steps", "5, 6, 7, 8", "убран из плеера"), "", "", ""},
		{logRow("info", "Steps", "5, 6, 7, 8", "убран на телефоне — файл ждёт подтверждения на компьютере"), "", "", ""},
		{logRow("added", "", "", "скачано (yandex)"), "", "", ""},
	}
	for _, c := range cases {
		it, ok := humanizeRow(c.row)
		if c.text == "" {
			if ok {
				t.Errorf("%s / %q должно быть шумом, а вышло: %+v", c.row.Kind, c.row.Detail, it)
			}
			continue
		}
		if !ok || it.Text != c.text || it.Icon != c.icon || it.Note != c.note {
			t.Errorf("%s / %q:\n  получилось: ok=%v icon=%q text=%q note=%q\n  ждали:      icon=%q text=%q note=%q",
				c.row.Kind, c.row.Detail, ok, it.Icon, it.Text, it.Note, c.icon, c.text, c.note)
		}
	}
}

func TestHumanizeLogCollapsesRepeatsAndCaps(t *testing.T) {
	start := logRow("info", "", "", "SoundFlow запущен (x)")
	rows := []localdb.ServerLogRow{start, start, logRow("added", "A", "B", "скачано (yandex)"), start}
	got := humanizeLog(rows, 10)
	if len(got) != 3 || got[0].Text != "Программа запущена" || got[0].N != 2 || got[1].Text != "Скачано: A — B" || got[2].N != 0 {
		t.Errorf("подряд одинаковые должны свернуться (×2), разные — нет: %+v", got)
	}
	var many []localdb.ServerLogRow
	for i := 0; i < 50; i++ {
		many = append(many, logRow("added", "A", "Песня "+string(rune('a'+i%26))+string(rune('A'+i/26)), "скачано (yandex)"))
	}
	if got := humanizeLog(many, 7); len(got) != 7 {
		t.Errorf("лимит строк: %d", len(got))
	}
	if got := humanizeLog(nil, 5); got == nil || len(got) != 0 {
		t.Errorf("пустая лента — пустой список, не null: %#v", got)
	}
}

func TestRuPlural(t *testing.T) {
	want := map[int]string{0: "песен", 1: "песня", 2: "песни", 4: "песни", 5: "песен", 11: "песен", 12: "песен", 21: "песня", 22: "песни", 25: "песен", 111: "песен", 101: "песня"}
	for n, w := range want {
		if got := ruPlural(n, "песня", "песни", "песен"); got != w {
			t.Errorf("%d → %q, ждали %q", n, got, w)
		}
	}
}

func TestRowsSinceCutsOldOnes(t *testing.T) {
	day := time.Date(2026, 9, 21, 0, 0, 0, 0, time.UTC)
	mk := func(h int, d string) localdb.ServerLogRow {
		r := logRow("info", "", "", d)
		r.At = day.Add(time.Duration(h) * time.Hour)
		return r
	}
	rows := []localdb.ServerLogRow{mk(9, "a"), mk(3, "b"), mk(-2, "вчера-1"), mk(-20, "вчера-2")} // новые сверху
	got := rowsSince(rows, day)
	if len(got) != 2 || got[0].Detail != "a" || got[1].Detail != "b" {
		t.Errorf("сегодняшних две: %+v", got)
	}
	if got := rowsSince(rows[:2], day); len(got) != 2 {
		t.Errorf("всё сегодняшнее должно остаться: %+v", got)
	}
	if got := rowsSince(rows[2:], day); len(got) != 0 {
		t.Errorf("всё вчерашнее должно уйти: %+v", got)
	}
}

func TestActivityHandlerShowsOnlyMeaningful(t *testing.T) {
	e := ctxFixture(t)
	db := e.s.db
	_ = db.AddServerLog("info", "Кино", "Группа крови", "поиск и скачивание запущены", 0)
	_ = db.AddServerLog("added", "Кино", "Группа крови", "скачано (yandex)", 0)
	_ = db.AddServerLog("not_found", "Nobody", "Nothing", "не нашёлся ни в одном источнике", 0)

	rec := httptest.NewRecorder()
	e.s.hActivity(rec, httptest.NewRequest("GET", "/api/activity", nil))
	if rec.Code != 200 {
		t.Fatalf("код %d: %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Date  string         `json:"date"`
		Items []activityItem `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	texts := []string{}
	for _, it := range out.Items {
		texts = append(texts, it.Text)
	}
	joined := strings.Join(texts, " | ")
	if len(out.Items) != 2 || out.Items[0].Text != "Не нашлось: Nobody — Nothing" || out.Items[1].Text != "Скачано: Кино — Группа крови" {
		t.Errorf("две строки, новые сверху; вышло: %s", joined)
	}
	if strings.Contains(joined, "поиск") {
		t.Errorf("шум попал в ленту: %s", joined)
	}
	if out.Date != time.Now().Format("2006-01-02") {
		t.Errorf("дата %q", out.Date)
	}
}
