package main

import (
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"soundflow/server/internal/localdb"
)

// «Активность» — что было сегодня, понятными фразами (ревизия 20.09.2026, `docs/revision-2026-09-20/05-one-press.md`,
// шаг 6, пункт С3). Технический «Журнал» (server_log) остаётся в «Настройках» как есть: он пишет для разбора («пересчёт
// завершён: посчитано 96, ошибок 1; первая причина: волна: ffmpeg…»). Здесь из той же ленты берём только то, что
// человеку интересно («скачано», «не нашлось», «скан добавил 31 песню»), и пишем по-человечески. Остальное — шум
// (395 записей «поиск запущен», 136 «скан завершён, добавлено 0») — в ленту не попадает.

type activityItem struct {
	At   time.Time `json:"at"`
	Icon string    `json:"icon"` // ok | warn | info
	Text string    `json:"text"`
	Note string    `json:"note,omitempty"`
	N    int       `json:"n,omitempty"` // сколько одинаковых строк подряд свёрнуто в эту (>1)
}

const activityMax = 100 // строк «Сегодня» отдаём не больше

var (
	reActScan      = regexp.MustCompile(`^скан завершён: добавлено (\d+), пропущено \d+, ошибок (\d+)`)
	reActPlan      = regexp.MustCompile(`^(?:из меню окна: в план телефона|план синхронизации сохранён:) \+(\d+) −(\d+)`)
	reActDeleted   = regexp.MustCompile(`^удалено навсегда из окна: (\d+) песен`)
	reActReconcile = regexp.MustCompile(`^каталог сверен с диском[^:]*: убрано песен (\d+)`)
	reActWave      = regexp.MustCompile(`^волна на сегодня собрана сама: (\d+) песен`)
	reActCovers    = regexp.MustCompile(`^обложки: проверено \d+.*?нашла в интернете (\d+)`)
	reActReindex   = regexp.MustCompile(`^пересчёт завершён: посчитано (\d+), ошибок (\d+)`)
)

// ruPlural — «1 песня, 2 песни, 5 песен».
func ruPlural(n int, one, few, many string) string {
	n100 := n % 100
	if n100 < 0 {
		n100 = -n100
	}
	n10 := n100 % 10
	switch {
	case n100 > 10 && n100 < 20:
		return many
	case n10 == 1:
		return one
	case n10 > 1 && n10 < 5:
		return few
	}
	return many
}

func songsN(n int) string {
	return fmt.Sprintf("%d %s", n, ruPlural(n, "песня", "песни", "песен"))
}

func atoiAct(s string) int { n, _ := strconv.Atoi(s); return n }

func artistTitle(r localdb.ServerLogRow) string {
	a, t := strings.TrimSpace(r.Artist), strings.TrimSpace(r.Title)
	switch {
	case a != "" && t != "":
		return a + " — " + t
	case t != "":
		return t
	}
	return a
}

// firstLine — первая строка текста, не длиннее n знаков (сообщения об ошибках бывают с целым трейсом).
func firstLine(s string, n int) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > n {
		s = string(r[:n]) + "…"
	}
	return s
}

// humanizeRow — одна запись журнала → строка «Активности»; ok=false — запись не для человека (шум).
func humanizeRow(r localdb.ServerLogRow) (activityItem, bool) {
	it := activityItem{At: r.At, Icon: "info"}
	d := strings.TrimSpace(r.Detail)
	who := artistTitle(r)
	switch r.Kind {
	case "added":
		if who == "" {
			return it, false
		}
		it.Icon, it.Text = "ok", "Скачано: "+who
		if i := strings.Index(d, "("); i >= 0 && strings.HasSuffix(d, ")") {
			it.Note = d[i+1 : len(d)-1] // «скачано (yandex)» → «yandex»
		}
		return it, true
	case "not_found":
		if who == "" {
			return it, false
		}
		it.Icon, it.Text, it.Note = "warn", "Не нашлось: "+who, d
		return it, true
	case "replaced":
		it.Icon, it.Text = "ok", "Заменена на версию получше: "+who
		return it, true
	case "removed":
		if who != "" && strings.Contains(d, "ищу замену") {
			it.Text = "Плохая версия убрана, ищу замену: " + who
			return it, true
		}
		return it, false // «убран из плеера» — про это говорит плашка «Убрано на телефоне», не лента
	case "error":
		switch {
		case d == "не найдено" && who != "":
			it.Icon, it.Text = "warn", "Не нашлось: "+who
		case strings.HasPrefix(r.Artist, "телефон ") && r.Title == "вылет приложения":
			it.Icon, it.Text, it.Note = "warn", "На телефоне вылетело приложение", "подробности — в журнале (Настройки)"
		case strings.HasPrefix(d, "сайдкар:"):
			it.Icon, it.Text, it.Note = "warn", "Качалка не ответила"+optWho(who), "программа запущена не полностью?"
		default:
			it.Icon, it.Text = "warn", "Ошибка: "+firstLine(d, 110)
			if who != "" {
				it.Note = who
			}
		}
		return it, true
	case "info":
		return humanizeInfo(it, d)
	}
	return it, false
}

func optWho(who string) string {
	if who == "" {
		return ""
	}
	return ": " + who
}

func humanizeInfo(it activityItem, d string) (activityItem, bool) {
	if m := reActScan.FindStringSubmatch(d); m != nil {
		added, errs := atoiAct(m[1]), atoiAct(m[2])
		switch {
		case errs > 0:
			it.Icon, it.Text = "warn", fmt.Sprintf("Скан папки: добавлено %s, с ошибками — %d", songsN(added), errs)
		case added > 0:
			it.Icon, it.Text = "ok", "Скан папки: добавлено "+songsN(added)
		default:
			return it, false // «добавлено 0» после каждой проверки — шум
		}
		return it, true
	}
	if m := reActPlan.FindStringSubmatch(d); m != nil {
		add, rem := atoiAct(m[1]), atoiAct(m[2])
		var parts []string
		if add > 0 {
			parts = append(parts, "добавить "+songsN(add))
		}
		if rem > 0 {
			parts = append(parts, "убрать "+songsN(rem))
		}
		if len(parts) == 0 {
			return it, false
		}
		it.Text = "В план для телефона: " + strings.Join(parts, ", ")
		return it, true
	}
	if strings.HasPrefix(d, "план телефона отменён") {
		it.Text = "План для телефона отменён"
		return it, true
	}
	if m := reActDeleted.FindStringSubmatch(d); m != nil {
		it.Text = "Стёрто из окна: " + songsN(atoiAct(m[1]))
		return it, true
	}
	if strings.HasPrefix(d, "удалён полностью из окна") {
		it.Text = "Песня стёрта из окна"
		return it, true
	}
	if m := reActReconcile.FindStringSubmatch(d); m != nil {
		n := atoiAct(m[1])
		if n == 0 {
			return it, false
		}
		it.Icon, it.Text, it.Note = "ok", "Каталог сверен с диском: убрано "+songsN(n), "файлов этих песен на диске нет"
		return it, true
	}
	if m := reActWave.FindStringSubmatch(d); m != nil {
		it.Icon, it.Text = "ok", "«Волна» на сегодня собрана: "+songsN(atoiAct(m[1]))
		return it, true
	}
	if m := reActCovers.FindStringSubmatch(d); m != nil {
		n := atoiAct(m[1])
		if n == 0 {
			return it, false
		}
		it.Icon, it.Text = "ok", fmt.Sprintf("Обложки: найдено %d", n)
		return it, true
	}
	if m := reActReindex.FindStringSubmatch(d); m != nil {
		done, errs := atoiAct(m[1]), atoiAct(m[2])
		switch {
		case errs > 0:
			it.Icon, it.Text = "warn", fmt.Sprintf("Отпечатки песен: посчитано %d, не вышло %d", done, errs)
		case done > 0:
			it.Icon, it.Text = "ok", fmt.Sprintf("Отпечатки песен посчитаны: %d", done)
		default:
			return it, false
		}
		return it, true
	}
	if strings.HasPrefix(d, "возврат песен с телефона") {
		it.Text = "Возврат песен с телефона на компьютер поставлен в очередь"
		return it, true
	}
	if strings.HasPrefix(d, "SoundFlow запущен") {
		it.Text = "Программа запущена"
		return it, true
	}
	return it, false
}

// humanizeLog — записи журнала (новые сверху) → строки «Активности» (новые сверху). Одинаковые строки подряд
// («Программа запущена» ×3) сворачиваются в одну с числом; не больше max строк.
func humanizeLog(rows []localdb.ServerLogRow, max int) []activityItem {
	out := []activityItem{}
	for _, r := range rows {
		it, ok := humanizeRow(r)
		if !ok {
			continue
		}
		if n := len(out); n > 0 && out[n-1].Text == it.Text && out[n-1].Icon == it.Icon {
			if out[n-1].N == 0 {
				out[n-1].N = 1
			}
			out[n-1].N++
			continue
		}
		out = append(out, it)
		if len(out) >= max {
			break
		}
	}
	return out
}

// GET /api/activity — что было сегодня (день — по времени компьютера) понятными фразами, новые сверху.
func (s *Service) hActivity(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.RecentServerLog(4000)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	now := time.Now()
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	writeJSON(w, map[string]any{"date": start.Format("2006-01-02"), "items": humanizeLog(rowsSince(rows, start), activityMax)})
}

// rowsSince — записи журнала (новые сверху) не старше start; порядок сохраняется.
func rowsSince(rows []localdb.ServerLogRow, start time.Time) []localdb.ServerLogRow {
	for i, row := range rows { // от новых к старым: первая же старая — дальше только старее
		if row.At.Before(start) {
			return rows[:i]
		}
	}
	return rows
}
