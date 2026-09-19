// Command soundflow-catalogfix — разовая починка каталога «двойные записи одной
// песни + сборники без тегов» (этап 120, Alex TG 19970/19979, 19.09.2026).
//
// Что делает:
//
//  1. Двойники. Одну и ту же песню каталог хранил дважды — две записи tracks,
//     привязанные к ОДНОМУ файлу (старая запись с испорченным ключом «iþøa__…»,
//     запись с номером трека в исполнителе «01. Deja Vu», болванка «Track 17»).
//     Из каждой пары остаётся одна — та, что с чистым исполнителем и здоровым
//     ключом; лишняя запись убирается ИЗ БАЗЫ (сам файл не трогаем — он общий),
//     её id дописывается в план телефона на удаление (телефон стирает свою копию
//     без события, окно подтверждения стирания не срабатывает), отметки
//     прослушиваний/пропусков переезжают на оставшуюся запись.
//  2. Сборники. У оставшихся записей из папок-сборников (имена файлов «01. …»,
//     «02. …», тега «альбом» нет) ставится альбом по имени папки, срезается номер
//     трека в исполнителе, болванка названия «Track N» берётся из имени файла.
//
// По умолчанию — СУХОЙ ПРОГОН: базу открывает только на чтение и печатает, что
// изменится. Применяет с -apply (одна транзакция). Перед -apply нужна копия базы
// и «да» Alex на список.
package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"soundflow/server/internal/quality"
)

// rec — одна запись каталога вместе с её файлом.
type rec struct {
	ID, Artist, Title, Album, Key, CreatedAt string
	CoverPath, CoverURL                      string
	CoverOK                                  int
	Year, Dur                                sql.NullInt64
	Energy, Valence                          sql.NullFloat64
	HasVec, HasWave                          bool
	FileID, FilePath, FileKey                string
}

func (r rec) label() string { return r.Artist + " — " + r.Title }

// merge — группа записей на один файл: keeper остаётся, losers убираем.
type merge struct {
	Keeper rec
	Losers []rec
	// Adopt — «лучшая» запись группы, когда её самой нет на телефоне, а другая
	// (Keeper) есть: чтобы песня не пропала с телефона и не качалась заново,
	// остаётся запись, лежащая на телефоне, но с данными лучшей (исполнитель,
	// название, альбом, ключ).
	Adopt *rec
	Why   []string // почему остаётся именно эта запись
	Flags []string // причины «проверить глазами» — такие группы НЕ применяем
}

// edit — правка оставшейся записи (сборник).
type edit struct {
	ID                   string
	OldArtist, NewArtist string
	OldTitle, NewTitle   string
	OldAlbum, NewAlbum   string
	OldKey, NewKey       string
	File                 string
}

type plan struct {
	Device    string
	Merges    []merge
	Edits     []edit
	Notes     []string // что пропущено и почему
	RemoveIDs []string // id убираемых записей, которые сейчас на телефоне
	TracksNow int
}

func (p *plan) applicable() []merge {
	var out []merge
	for _, m := range p.Merges {
		if len(m.Flags) == 0 {
			out = append(out, m)
		}
	}
	return out
}

func main() {
	dbPath := flag.String("db", "", "путь к soundflow.db")
	apply := flag.Bool("apply", false, "применить (без флага — сухой прогон, база только на чтение)")
	device := flag.String("device", "", "id телефона для плана удаления (по умолчанию — последний по last_sync_at)")
	report := flag.String("report", "", "куда записать отчёт (по умолчанию — только на экран)")
	flag.Parse()
	if *dbPath == "" {
		fmt.Fprintln(os.Stderr, "нужен -db <путь к soundflow.db>")
		os.Exit(2)
	}
	if err := run(*dbPath, *apply, *device, *report, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "ОШИБКА:", err)
		os.Exit(1)
	}
}

func run(dbPath string, apply bool, device, reportPath string, out io.Writer) error {
	dsn := "file:" + filepath.ToSlash(dbPath) + "?mode=ro&_pragma=busy_timeout(30000)"
	if apply {
		dsn = "file:" + filepath.ToSlash(dbPath) + "?mode=rw&_pragma=busy_timeout(30000)&_pragma=foreign_keys(1)"
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	p, err := buildPlan(db, device)
	if err != nil {
		return err
	}
	mode := "СУХОЙ ПРОГОН (база не менялась)"
	if apply {
		mode = "ПРИМЕНЕНО"
	}
	var sb strings.Builder
	writeReport(&sb, p, mode)
	if apply {
		before := p.TracksNow
		if err := applyPlan(db, p); err != nil {
			return fmt.Errorf("применение (транзакция откатена): %w", err)
		}
		probs, err := verify(db, before, p)
		if err != nil {
			return err
		}
		sb.WriteString("\n== Проверка после применения ==\n")
		if len(probs) == 0 {
			sb.WriteString("все проверки прошли\n")
		}
		for _, s := range probs {
			sb.WriteString("ПРОБЛЕМА: " + s + "\n")
		}
		if len(probs) > 0 {
			io.WriteString(out, sb.String())
			return errors.New("после применения проверка нашла проблемы — см. отчёт, откат из копии базы")
		}
	}
	io.WriteString(out, sb.String())
	if reportPath != "" {
		return os.WriteFile(reportPath, []byte(sb.String()), 0o644)
	}
	return nil
}

// ---------- загрузка ----------

func load(db *sql.DB) ([]rec, error) {
	rows, err := db.Query(`
		SELECT t.id, t.artist, t.title, COALESCE(t.album,''), COALESCE(t.normalized_key,''), COALESCE(t.created_at,''),
		       COALESCE(t.cover_path,''), COALESCE(t.cover_url,''), COALESCE(t.cover_ok,0),
		       t.year, t.duration_sec, t.energy, t.valence,
		       t.feature_vector IS NOT NULL, t.waveform IS NOT NULL,
		       f.id, f.file_path, COALESCE(f.normalized_key,'')
		FROM tracks t
		JOIN track_files f ON f.track_id = t.id AND COALESCE(f.rejected,0) = 0
		ORDER BY t.created_at, t.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []rec
	for rows.Next() {
		var r rec
		if err := rows.Scan(&r.ID, &r.Artist, &r.Title, &r.Album, &r.Key, &r.CreatedAt,
			&r.CoverPath, &r.CoverURL, &r.CoverOK, &r.Year, &r.Dur, &r.Energy, &r.Valence,
			&r.HasVec, &r.HasWave, &r.FileID, &r.FilePath, &r.FileKey); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// onDevice — что сейчас на телефоне (та же логика, что localdb.DeviceTrackIDs).
func onDevice(db *sql.DB, dev string) (map[string]bool, error) {
	rows, err := db.Query(`
		SELECT track_id,
		       MAX(CASE WHEN kind='download' THEN applied_at END),
		       MAX(CASE WHEN kind='delete'   THEN applied_at END)
		FROM sync_events
		WHERE device_id=? AND track_id<>'' AND kind IN ('download','delete')
		GROUP BY track_id`, dev)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var id string
		var dl, del sql.NullString
		if err := rows.Scan(&id, &dl, &del); err != nil {
			return nil, err
		}
		if dl.Valid && (!del.Valid || dl.String > del.String) {
			out[id] = true
		}
	}
	return out, rows.Err()
}

func pickDevice(db *sql.DB, want string) (string, error) {
	if want != "" {
		return want, nil
	}
	var id string
	err := db.QueryRow(`SELECT id FROM devices ORDER BY COALESCE(last_sync_at,'') DESC LIMIT 1`).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// ---------- план ----------

var looseNum = regexp.MustCompile(`^\d{1,3}\s+`)

// looseArtist — исполнитель «для сравнения»: без номера трека («01. », «17 »),
// в нижнем регистре.
func looseArtist(s string) string {
	s = strings.ToLower(strings.TrimSpace(quality.StripLeadingTrackNumber(s)))
	return strings.TrimSpace(looseNum.ReplaceAllString(s, ""))
}

// compare — чья запись лучше как «оставшаяся»: >0 — a, <0 — b, 0 — ничья.
// Критерии по порядку; why — какой сработал.
func compare(a, b rec) (int, string) {
	type crit struct {
		name string
		f    func(rec) bool
	}
	for _, c := range []crit{
		{"у другой название-болванка «Track N»", func(r rec) bool { return !quality.IsGenericTrackTitle(r.Title) }},
		{"у другой номер трека в исполнителе", func(r rec) bool { return quality.StripLeadingTrackNumber(r.Artist) == r.Artist }},
		{"у другой испорченный ключ", func(r rec) bool { return r.Key == quality.NormalizedKey(r.Artist, r.Title) }},
		{"у другой нет альбома", func(r rec) bool { return strings.TrimSpace(r.Album) != "" }},
	} {
		fa, fb := c.f(a), c.f(b)
		if fa != fb {
			if fa {
				return 1, c.name
			}
			return -1, c.name
		}
	}
	if len(a.Artist) != len(b.Artist) {
		if len(a.Artist) > len(b.Artist) {
			return 1, "у другой исполнитель обрезан"
		}
		return -1, "у другой исполнитель обрезан"
	}
	if a.HasVec != b.HasVec {
		if a.HasVec {
			return 1, "у другой нет звукового отпечатка"
		}
		return -1, "у другой нет звукового отпечатка"
	}
	if a.CreatedAt != b.CreatedAt {
		if a.CreatedAt < b.CreatedAt {
			return 1, "старше"
		}
		return -1, "старше"
	}
	if a.ID < b.ID {
		return 1, "порядок id"
	}
	return -1, "порядок id"
}

func audioNamesIn(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	audio := map[string]bool{".mp3": true, ".flac": true, ".m4a": true, ".ogg": true, ".opus": true, ".wav": true, ".aac": true, ".wma": true}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && audio[strings.ToLower(filepath.Ext(e.Name()))] {
			names = append(names, e.Name())
		}
	}
	return names
}

func titleFromFile(path string) string {
	base := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	for _, sep := range []string{" - ", " — ", " – "} {
		if i := strings.Index(base, sep); i > 0 {
			return strings.TrimSpace(base[i+len(sep):])
		}
	}
	return ""
}

func buildPlan(db *sql.DB, device string) (*plan, error) {
	recs, err := load(db)
	if err != nil {
		return nil, err
	}
	p := &plan{TracksNow: len(recs)}
	if p.Device, err = pickDevice(db, device); err != nil {
		return nil, err
	}
	have := map[string]bool{}
	if p.Device != "" {
		if have, err = onDevice(db, p.Device); err != nil {
			return nil, err
		}
	}
	pending := map[string]bool{}
	if rows, err := db.Query(`SELECT track_id FROM pending_removals`); err == nil {
		for rows.Next() {
			var id string
			_ = rows.Scan(&id)
			pending[id] = true
		}
		rows.Close()
	}

	// --- двойники: группы записей на один файл ---
	byFile := map[string][]rec{}
	for _, r := range recs {
		k := strings.ToLower(filepath.Clean(r.FilePath))
		byFile[k] = append(byFile[k], r)
	}
	keys := make([]string, 0, len(byFile))
	for k, g := range byFile {
		if len(g) > 1 {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	final := map[string]rec{} // что будет в записи после починки (сперва — как сейчас)
	for _, r := range recs {
		final[r.ID] = r
	}
	for _, k := range keys {
		g := byFile[k]
		sort.SliceStable(g, func(i, j int) bool { c, _ := compare(g[i], g[j]); return c > 0 })
		best := g[0]
		m := merge{Keeper: best}
		if p.Device != "" && !have[best.ID] {
			for _, c := range g[1:] {
				if have[c.ID] {
					b := best
					m.Keeper, m.Adopt = c, &b
					m.Why = append(m.Why, "остаётся запись, которая уже лежит на телефоне (данные — от лучшей записи)")
					break
				}
			}
		}
		for _, r := range g {
			if r.ID != m.Keeper.ID {
				m.Losers = append(m.Losers, r)
			}
		}
		for _, o := range g[1:] {
			if _, why := compare(best, o); why != "" {
				m.Why = append(m.Why, why)
			}
			// флаги «проверить глазами»
			if !quality.IsGenericTrackTitle(best.Title) && !quality.IsGenericTrackTitle(o.Title) &&
				!strings.EqualFold(strings.TrimSpace(best.Title), strings.TrimSpace(o.Title)) {
				m.Flags = append(m.Flags, fmt.Sprintf("названия разные: «%s» / «%s»", best.Title, o.Title))
			}
			ka, la := looseArtist(best.Artist), looseArtist(o.Artist)
			if ka != la && !strings.HasPrefix(ka, la) && !strings.HasPrefix(la, ka) {
				m.Flags = append(m.Flags, fmt.Sprintf("исполнители разные: «%s» / «%s»", best.Artist, o.Artist))
			}
		}
		for _, r := range g {
			if pending[r.ID] {
				m.Flags = append(m.Flags, "запись ждёт подтверждения стирания")
				break
			}
		}
		if len(g) > 2 {
			m.Flags = append(m.Flags, fmt.Sprintf("записей на файл больше двух (%d)", len(g)))
		}
		p.Merges = append(p.Merges, m)
		if len(m.Flags) > 0 {
			p.Notes = append(p.Notes, fmt.Sprintf("ПРОПУЩЕНА пара «%s» / «%s»: %s", best.label(), g[1].label(), strings.Join(m.Flags, "; ")))
			continue
		}
		for _, l := range m.Losers {
			delete(final, l.ID)
			if p.Device != "" && have[l.ID] {
				p.RemoveIDs = append(p.RemoveIDs, l.ID)
			}
		}
		if m.Adopt != nil {
			s := final[m.Keeper.ID]
			a := *m.Adopt
			s.Artist, s.Title, s.Album, s.Key, s.FileKey = a.Artist, a.Title, a.Album, a.Key, a.Key
			final[m.Keeper.ID] = s
		}
	}

	// --- сборники: правки оставшихся записей ---
	type dirInfo struct {
		numbered bool
		album    string
	}
	dirs := map[string]dirInfo{}
	usedKey := map[string]string{} // track_files.normalized_key → track_id (оставшиеся записи, как будут)
	for _, r := range final {
		usedKey[r.FileKey] = r.ID
	}
	for _, orig := range recs {
		cur, alive := final[orig.ID]
		if !alive {
			continue
		}
		dir := filepath.Dir(orig.FilePath)
		di, ok := dirs[dir]
		if !ok {
			if quality.LooksLikeNumberedAlbum(audioNamesIn(dir)) {
				di = dirInfo{numbered: true, album: quality.AlbumFromFolder(dir)}
			}
			dirs[dir] = di
		}
		e := edit{ID: orig.ID, OldArtist: orig.Artist, OldTitle: orig.Title, OldAlbum: orig.Album, OldKey: orig.Key,
			NewArtist: cur.Artist, NewTitle: cur.Title, NewAlbum: cur.Album, NewKey: cur.Key, File: filepath.Base(orig.FilePath)}
		if di.numbered {
			if strings.TrimSpace(cur.Album) == "" && di.album != "" {
				e.NewAlbum = di.album
			}
			newArtist := quality.StripLeadingTrackNumber(cur.Artist)
			newTitle := cur.Title
			if quality.IsGenericTrackTitle(cur.Title) {
				if t := titleFromFile(orig.FilePath); t != "" {
					newTitle = t
				}
			}
			if newArtist != cur.Artist || newTitle != cur.Title {
				e.NewArtist, e.NewTitle = newArtist, newTitle
				cand := quality.NormalizedKey(newArtist, newTitle)
				if other, taken := usedKey[cand]; taken && other != orig.ID {
					// та же песня уже есть отдельным файлом (другая версия): номер срезаем,
					// а ключ оставляем прежним — он уникален для файла
					p.Notes = append(p.Notes, fmt.Sprintf("ключ «%s» занят другой записью %s (та же песня отдельным файлом): у «%s» номер срезан, ключ прежний", cand, other, orig.label()))
				} else {
					delete(usedKey, cur.FileKey)
					usedKey[cand] = orig.ID
					e.NewKey = cand
				}
			}
		}
		if e.NewArtist != e.OldArtist || e.NewTitle != e.OldTitle || e.NewAlbum != e.OldAlbum || e.NewKey != e.OldKey {
			p.Edits = append(p.Edits, e)
		}
	}
	return p, nil
}

// ---------- отчёт ----------

func writeReport(w io.Writer, p *plan, mode string) {
	fmt.Fprintf(w, "SoundFlow — починка каталога (этап 120). Режим: %s\n", mode)
	fmt.Fprintf(w, "Записей в каталоге сейчас: %d. Телефон для плана удаления: %s\n\n", p.TracksNow, orDash(p.Device))

	app := p.applicable()
	fmt.Fprintf(w, "== 1. Двойные записи одной песни: пар найдено %d, будет слито %d, пропущено %d ==\n", len(p.Merges), len(app), len(p.Merges)-len(app))
	perDir := map[string]int{}
	for _, m := range app {
		perDir[filepath.Dir(m.Keeper.FilePath)]++
	}
	dirsSorted := make([]string, 0, len(perDir))
	for d := range perDir {
		dirsSorted = append(dirsSorted, d)
	}
	sort.Strings(dirsSorted)
	for _, d := range dirsSorted {
		fmt.Fprintf(w, "  %4d  %s\n", perDir[d], d)
	}
	fmt.Fprintln(w)
	for i, m := range p.Merges {
		mark := "ОСТАВИТЬ"
		if len(m.Flags) > 0 {
			mark = "ПРОПУЩЕНО"
		}
		fmt.Fprintf(w, "%3d. [%s] %s  {%s, ключ %s}\n", i+1, mark, m.Keeper.label(), shortID(m.Keeper.ID), m.Keeper.Key)
		if m.Adopt != nil {
			fmt.Fprintf(w, "       данные берутся у %s: %s, ключ %s\n", shortID(m.Adopt.ID), m.Adopt.label(), m.Adopt.Key)
		}
		for _, l := range m.Losers {
			fmt.Fprintf(w, "       [убрать] %s  {%s, ключ %s}\n", l.label(), shortID(l.ID), l.Key)
		}
		fmt.Fprintf(w, "       причина: %s; файл: %s\n", strings.Join(uniq(m.Why), "; "), filepath.Base(m.Keeper.FilePath))
		for _, f := range m.Flags {
			fmt.Fprintf(w, "       !!! %s\n", f)
		}
	}

	fmt.Fprintf(w, "\n== 2. Сборники: правки оставшихся записей: %d ==\n", len(p.Edits))
	tiles := map[string]int{}
	for _, e := range p.Edits {
		if e.NewAlbum != "" && e.NewAlbum != e.OldAlbum {
			tiles[e.NewAlbum]++
		}
	}
	tn := make([]string, 0, len(tiles))
	for a := range tiles {
		tn = append(tn, a)
	}
	sort.Strings(tn)
	fmt.Fprintln(w, "Плитки в каталоге после правки (альбом → песен из этой починки):")
	for _, a := range tn {
		fmt.Fprintf(w, "  %4d  %s\n", tiles[a], a)
	}
	fmt.Fprintln(w)
	for _, e := range p.Edits {
		var ch []string
		if e.NewArtist != e.OldArtist {
			ch = append(ch, fmt.Sprintf("исполнитель «%s» → «%s»", e.OldArtist, e.NewArtist))
		}
		if e.NewTitle != e.OldTitle {
			ch = append(ch, fmt.Sprintf("название «%s» → «%s»", e.OldTitle, e.NewTitle))
		}
		if e.NewAlbum != e.OldAlbum {
			ch = append(ch, fmt.Sprintf("альбом «%s» → «%s»", e.OldAlbum, e.NewAlbum))
		}
		if e.NewKey != e.OldKey {
			ch = append(ch, fmt.Sprintf("ключ «%s» → «%s»", e.OldKey, e.NewKey))
		}
		fmt.Fprintf(w, "  %s  %s: %s\n", shortID(e.ID), e.File, strings.Join(ch, "; "))
	}

	fmt.Fprintf(w, "\n== 3. Телефон: в план удаления будет дописано %d записей ==\n", len(p.RemoveIDs))
	if len(p.Notes) > 0 {
		fmt.Fprintf(w, "\n== Замечания (%d) ==\n", len(p.Notes))
		for _, n := range p.Notes {
			fmt.Fprintln(w, " - "+n)
		}
	}
	fmt.Fprintf(w, "\nИтого: записей было %d, станет %d. Файлы с музыкой не трогаются.\n", p.TracksNow, p.TracksNow-losersCount(app))
}

func losersCount(ms []merge) int {
	n := 0
	for _, m := range ms {
		n += len(m.Losers)
	}
	return n
}

func shortID(id string) string {
	if len(id) > 10 {
		return id[:10]
	}
	return id
}

func orDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

func uniq(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// ---------- применение ----------

func applyPlan(db *sql.DB, p *plan) (err error) {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()

	for _, m := range p.applicable() {
		k := m.Keeper
		for _, l := range m.Losers {
			// недостающие данные оставляемой записи берём у убираемой
			for _, col := range []string{"feature_vector", "waveform", "energy", "valence", "year", "duration_sec"} {
				if _, err = tx.Exec(`UPDATE tracks SET `+col+` = (SELECT `+col+` FROM tracks WHERE id=?1)
					WHERE id=?2 AND `+col+` IS NULL AND (SELECT `+col+` FROM tracks WHERE id=?1) IS NOT NULL`, l.ID, k.ID); err != nil {
					return fmt.Errorf("перенос %s: %w", col, err)
				}
			}
			if _, err = tx.Exec(`UPDATE tracks SET
					cover_path=(SELECT cover_path FROM tracks WHERE id=?1),
					cover_ok=(SELECT cover_ok FROM tracks WHERE id=?1),
					cover_url=CASE WHEN cover_url='' THEN (SELECT cover_url FROM tracks WHERE id=?1) ELSE cover_url END
				WHERE id=?2 AND COALESCE(cover_path,'')='' AND COALESCE((SELECT cover_path FROM tracks WHERE id=?1),'')<>''`, l.ID, k.ID); err != nil {
				return fmt.Errorf("перенос обложки: %w", err)
			}
			// отметки прослушиваний/пропусков — на оставшуюся запись
			if _, err = tx.Exec(`UPDATE feedback_event SET track_id=?, artist=? WHERE track_id=?`, k.ID, k.Artist, l.ID); err != nil {
				return fmt.Errorf("feedback_event: %w", err)
			}
			if _, err = tx.Exec(`UPDATE sync_events SET track_id=? WHERE track_id=? AND kind NOT IN ('download','delete')`, k.ID, l.ID); err != nil {
				return fmt.Errorf("sync_events (перепривязка): %w", err)
			}
			// «лежит на телефоне» — свойство id; у убираемой записи оно исчезает
			if _, err = tx.Exec(`DELETE FROM sync_events WHERE track_id=? AND kind IN ('download','delete')`, l.ID); err != nil {
				return fmt.Errorf("sync_events (удаление): %w", err)
			}
			if _, err = tx.Exec(`DELETE FROM track_files WHERE track_id=?`, l.ID); err != nil {
				return fmt.Errorf("track_files: %w", err)
			}
			if _, err = tx.Exec(`DELETE FROM tracks WHERE id=?`, l.ID); err != nil {
				return fmt.Errorf("tracks: %w", err)
			}
		}
	}

	for _, e := range p.Edits {
		search := strings.ToLower(e.NewArtist + " " + e.NewTitle + " " + e.NewAlbum)
		if _, err = tx.Exec(`UPDATE tracks SET artist=?, title=?, album=?, normalized_key=?, search_text=? WHERE id=?`,
			e.NewArtist, e.NewTitle, e.NewAlbum, e.NewKey, search, e.ID); err != nil {
			return fmt.Errorf("правка %s: %w", e.ID, err)
		}
		if e.NewKey != e.OldKey {
			if _, err = tx.Exec(`UPDATE track_files SET normalized_key=? WHERE track_id=?`, e.NewKey, e.ID); err != nil {
				return fmt.Errorf("ключ файла %s: %w", e.ID, err)
			}
		}
		if e.NewArtist != e.OldArtist {
			if _, err = tx.Exec(`UPDATE feedback_event SET artist=? WHERE track_id=?`, e.NewArtist, e.ID); err != nil {
				return fmt.Errorf("feedback %s: %w", e.ID, err)
			}
		}
	}

	if p.Device != "" && len(p.RemoveIDs) > 0 {
		if err = addToPlanRemove(tx, p.Device, p.RemoveIDs); err != nil {
			return fmt.Errorf("план телефона: %w", err)
		}
	}
	msg := fmt.Sprintf("каталог: слито %d двойных записей одной песни, поправлено %d записей сборников (этап 120)", losersCount(p.applicable()), len(p.Edits))
	if _, err = tx.Exec(`INSERT INTO server_log (at,kind,artist,title,detail,bytes) VALUES (?,?,?,?,?,0)`,
		time.Now().UTC().Format(time.RFC3339Nano), "info", "", "", msg); err != nil {
		return err
	}
	return tx.Commit()
}

// addToPlanRemove — дописать ids в remove_ids плана устройства, не трогая остальное.
func addToPlanRemove(tx *sql.Tx, dev string, ids []string) error {
	var addJSON, remJSON string
	err := tx.QueryRow(`SELECT add_ids, remove_ids FROM sync_plans WHERE device_id=?`, dev).Scan(&addJSON, &remJSON)
	if errors.Is(err, sql.ErrNoRows) {
		addJSON, remJSON, err = "[]", "[]", nil
	}
	if err != nil {
		return err
	}
	var add, rem []string
	_ = json.Unmarshal([]byte(addJSON), &add)
	_ = json.Unmarshal([]byte(remJSON), &rem)
	gone := map[string]bool{}
	for _, id := range ids {
		gone[id] = true
	}
	newAdd := add[:0]
	for _, x := range add {
		if !gone[x] {
			newAdd = append(newAdd, x)
		}
	}
	have := map[string]bool{}
	for _, x := range rem {
		have[x] = true
	}
	for _, id := range ids {
		if !have[id] {
			rem = append(rem, id)
		}
	}
	a, _ := json.Marshal(newAdd)
	r, _ := json.Marshal(rem)
	_, err = tx.Exec(`
		INSERT INTO sync_plans (device_id, add_ids, remove_ids, created_at) VALUES (?,?,?,?)
		ON CONFLICT(device_id) DO UPDATE SET add_ids=excluded.add_ids, remove_ids=excluded.remove_ids, created_at=excluded.created_at`,
		dev, string(a), string(r), time.Now().UTC().Format(time.RFC3339))
	return err
}

// ---------- проверка после применения ----------

func verify(db *sql.DB, tracksBefore int, p *plan) ([]string, error) {
	var probs []string
	one := func(q string, args ...any) (int, error) {
		var n int
		err := db.QueryRow(q, args...).Scan(&n)
		return n, err
	}
	now, err := one(`SELECT COUNT(*) FROM tracks`)
	if err != nil {
		return nil, err
	}
	if want := tracksBefore - losersCount(p.applicable()); now != want {
		probs = append(probs, fmt.Sprintf("записей %d, ждали %d", now, want))
	}
	if n, _ := one(`SELECT COUNT(*) FROM track_files WHERE track_id NOT IN (SELECT id FROM tracks)`); n != 0 {
		probs = append(probs, fmt.Sprintf("файловых записей без трека: %d", n))
	}
	if n, _ := one(`SELECT COUNT(*) FROM tracks WHERE id NOT IN (SELECT track_id FROM track_files WHERE COALESCE(rejected,0)=0)`); n != 0 {
		probs = append(probs, fmt.Sprintf("треков без файла: %d", n))
	}
	left, _ := one(`SELECT COUNT(*) FROM (SELECT 1 FROM track_files WHERE COALESCE(rejected,0)=0
		GROUP BY lower(file_path) HAVING COUNT(DISTINCT track_id) > 1)`)
	if want := len(p.Merges) - len(p.applicable()); left != want {
		probs = append(probs, fmt.Sprintf("файлов с двумя записями осталось %d, ждали %d (пропущенные)", left, want))
	}
	for _, m := range p.applicable() {
		if n, _ := one(`SELECT COUNT(*) FROM tracks WHERE id=?`, m.Keeper.ID); n != 1 {
			probs = append(probs, "нет оставляемой записи "+m.Keeper.ID)
		}
		for _, l := range m.Losers {
			if n, _ := one(`SELECT COUNT(*) FROM tracks WHERE id=?`, l.ID); n != 0 {
				probs = append(probs, "убираемая запись ещё есть "+l.ID)
			}
			if n, _ := one(`SELECT COUNT(*) FROM sync_events WHERE track_id=? AND kind IN ('download','delete')`, l.ID); n != 0 {
				probs = append(probs, "у убираемой записи остались события «на телефоне» "+l.ID)
			}
		}
	}
	rows, err := db.Query(`PRAGMA foreign_key_check`)
	if err == nil {
		n := 0
		for rows.Next() {
			n++
		}
		rows.Close()
		if n != 0 {
			probs = append(probs, fmt.Sprintf("foreign_key_check: %d нарушений", n))
		}
	}
	var ic string
	if err := db.QueryRow(`PRAGMA integrity_check`).Scan(&ic); err != nil || ic != "ok" {
		probs = append(probs, "integrity_check: "+ic)
	}
	return probs, nil
}
