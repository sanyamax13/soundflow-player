package localdb

import "time"

// «Удалить» во вкладке «Открытия» (Alex TG 20073, 19.09.2026): песню можно убрать из списков
// волны / лайков Яндекса / старых лайков телефона. Это ТОЛЬКО скрытие в этих списках:
// лайк в Яндексе, лайк на телефоне, метка «больше не качать» и сам каталог не трогаются,
// и обратно можно вернуть (UndismissDiscover). Ключ — тот же normalized_key (артист+название),
// что и везде в проекте.

// DismissDiscover — скрыть песню из списков «Открытий».
func (d *DB) DismissDiscover(key, artist, title string) error {
	if key == "" {
		return nil
	}
	_, err := d.sql.Exec(`
		INSERT INTO discover_dismissed (normalized_key, artist, title, dismissed_at)
		VALUES (?,?,?,?)
		ON CONFLICT(normalized_key) DO UPDATE SET dismissed_at=excluded.dismissed_at`,
		key, artist, title, time.Now().UTC().Format(time.RFC3339))
	return err
}

// UndismissDiscover — вернуть скрытую песню в списки.
func (d *DB) UndismissDiscover(key string) error {
	_, err := d.sql.Exec(`DELETE FROM discover_dismissed WHERE normalized_key = ?`, key)
	return err
}

// DismissedDiscover — множество скрытых ключей (для фильтра списков одним запросом).
func (d *DB) DismissedDiscover() (map[string]bool, error) {
	rows, err := d.sql.Query(`SELECT normalized_key FROM discover_dismissed`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, err
		}
		out[k] = true
	}
	return out, rows.Err()
}
