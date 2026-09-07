// soundflow-apidiff — сверка телефонного API: старый srv.exe против нового
// soundflow-srv на SQLite. Гоняет один и тот же набор запросов на оба адреса,
// выкидывает заведомо разные поля (uptime, server_time, время лога) и
// показывает расхождения.
//
//	go run ./cmd/soundflow-apidiff -old http://127.0.0.1:18090 -new http://127.0.0.1:8093 -device <id>
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"reflect"
	"sort"
	"strings"
	"time"
)

type check struct {
	name   string
	method string
	path   string
	body   string
	// scrub убирает волатильные поля перед сравнением.
	scrub func(any) any
	// idsOnly: для списков треков сверяем только множество id (порядок/динамические поля неважны).
	idsPath string
}

func main() {
	oldURL := flag.String("old", "http://127.0.0.1:18090", "старый srv.exe")
	newURL := flag.String("new", "http://127.0.0.1:8093", "новый soundflow-srv")
	device := flag.String("device", "", "id устройства для sync/report")
	flag.Parse()

	checks := []check{
		{name: "health", method: "GET", path: "/v1/health"},
		{name: "tracks?limit=100", method: "GET", path: "/v1/tracks?limit=100", idsPath: "tracks"},
		{name: "search love", method: "GET", path: "/v1/search?q=love&limit=50", idsPath: "tracks"},
		{name: "search ночь", method: "GET", path: "/v1/search?q=" + urlq("ночь") + "&limit=50", idsPath: "tracks"},
		{name: "search би-2", method: "GET", path: "/v1/search?q=" + urlq("би-2") + "&limit=50", idsPath: "tracks"},
		{name: "search remix", method: "GET", path: "/v1/search?q=remix&limit=50", idsPath: "tracks"},
		{name: "trash", method: "GET", path: "/v1/trash", idsPath: "tracks"},
		{name: "admin/blocklist", method: "GET", path: "/v1/admin/blocklist"},
		{name: "admin/devices", method: "GET", path: "/v1/admin/devices", scrub: scrubDevices},
		{name: "admin/status", method: "GET", path: "/v1/admin/status", scrub: scrubStatus},
		{name: "admin/events?limit=30", method: "GET", path: "/v1/admin/events?limit=30", scrub: scrubList},
		{name: "next-batch", method: "POST", path: "/v1/library/next-batch", body: `{"exclude_ids":[],"budget_bytes":52428800}`, idsPath: "tracks"},
	}
	if *device != "" {
		checks = append(checks, check{name: "sync/report", method: "GET", path: "/v1/sync/report?device=" + *device, scrub: scrubReport})
	}

	fail := 0
	for _, c := range checks {
		ov, oerr := fetch(*oldURL+c.path, c.method, c.body)
		nv, nerr := fetch(*newURL+c.path, c.method, c.body)
		if oerr != nil || nerr != nil {
			fmt.Printf("· %-22s  ЗАПРОС НЕ ПРОШЁЛ  old=%v new=%v\n", c.name, oerr, nerr)
			fail++
			continue
		}
		var a, b any = ov, nv
		if c.idsPath != "" {
			a, b = idset(ov, c.idsPath), idset(nv, c.idsPath)
		} else if c.scrub != nil {
			a, b = c.scrub(ov), c.scrub(nv)
		}
		if reflect.DeepEqual(a, b) {
			extra := ""
			if c.idsPath != "" {
				extra = fmt.Sprintf(" (%d id)", len(a.([]string)))
			}
			fmt.Printf("✓ %-22s  совпало%s\n", c.name, extra)
			continue
		}
		fail++
		fmt.Printf("✗ %-22s  РАСХОЖДЕНИЕ\n", c.name)
		if c.idsPath != "" {
			as, bs := a.([]string), b.([]string)
			fmt.Printf("    только в старом: %s\n", short(diff(as, bs)))
			fmt.Printf("    только в новом:  %s\n", short(diff(bs, as)))
		} else {
			fmt.Printf("    old: %s\n", short1(a))
			fmt.Printf("    new: %s\n", short1(b))
		}
	}
	fmt.Printf("\nитого: %d проверок, расхождений %d\n", len(checks), fail)
	if fail > 0 {
		os.Exit(1)
	}
}

func urlq(s string) string {
	r := strings.NewReplacer(" ", "%20")
	out := &strings.Builder{}
	for _, b := range []byte(s) {
		if b < 0x80 && (b == '-' || b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9') {
			out.WriteByte(b)
		} else {
			fmt.Fprintf(out, "%%%02X", b)
		}
	}
	_ = r
	return out.String()
}

func fetch(url, method, body string) (any, error) {
	var rdr io.Reader
	if body != "" {
		rdr = bytes.NewReader([]byte(body))
	}
	req, err := http.NewRequest(method, url, rdr)
	if err != nil {
		return nil, err
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	cl := &http.Client{Timeout: 30 * time.Second}
	resp, err := cl.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(raw))[:min(80, len(strings.TrimSpace(string(raw))))])
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, fmt.Errorf("не JSON: %v", err)
	}
	return v, nil
}

func idset(v any, key string) []string {
	m, _ := v.(map[string]any)
	arr, _ := m[key].([]any)
	out := make([]string, 0, len(arr))
	for _, it := range arr {
		o, _ := it.(map[string]any)
		for _, k := range []string{"id", "track_id"} {
			if s, ok := o[k].(string); ok {
				out = append(out, s)
				break
			}
		}
	}
	sort.Strings(out)
	return out
}

func diff(a, b []string) []string {
	mb := map[string]bool{}
	for _, x := range b {
		mb[x] = true
	}
	var out []string
	for _, x := range a {
		if !mb[x] {
			out = append(out, x)
		}
	}
	return out
}

func scrubStatus(v any) any {
	m, _ := v.(map[string]any)
	if m == nil {
		return v
	}
	delete(m, "uptime_sec")
	delete(m, "server_time")
	delete(m, "go_version")
	delete(m, "busy")
	delete(m, "music_source")
	delete(m, "migrations")
	if r, ok := m["report"].(map[string]any); ok {
		delete(r, "since")
	}
	return m
}

func scrubDevices(v any) any {
	m, _ := v.(map[string]any)
	arr, _ := m["devices"].([]any)
	for _, it := range arr {
		o, _ := it.(map[string]any)
		delete(o, "events") // старый не отдаёт, новый мог бы
	}
	return m
}

func scrubReport(v any) any {
	m, _ := v.(map[string]any)
	if m == nil {
		return v
	}
	delete(m, "last_sync_at")
	return m
}

func scrubList(v any) any {
	m, _ := v.(map[string]any)
	if m == nil {
		return v
	}
	for _, val := range m {
		if arr, ok := val.([]any); ok {
			for _, it := range arr {
				if o, ok := it.(map[string]any); ok {
					delete(o, "id")
					delete(o, "at")
					delete(o, "applied_at")
					delete(o, "client_ts")
				}
			}
		}
	}
	return m
}

func short(xs []string) string {
	if len(xs) == 0 {
		return "—"
	}
	if len(xs) > 12 {
		return fmt.Sprintf("%v … (+%d)", xs[:12], len(xs)-12)
	}
	return fmt.Sprint(xs)
}

func short1(v any) string {
	b, _ := json.Marshal(v)
	s := string(b)
	if len(s) > 400 {
		return s[:400] + "…"
	}
	return s
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
