package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// Окно строит страницу из строк, которые приходят снаружи (название песни из тегов, имя телефона,
// присылаемое телефоном). Ревизия 20.09.2026 (пункт 1г): `esc` не трогал кавычки, и имя с ' или "
// ломало (а при желании — подменяло) inline-обработчик `onclick="f('${esc(x)}')"`. Теперь `esc`
// экранирует и кавычки, а в обработчиках строки идут через `jsArg` (JS-литерал, потом HTML-экранирование:
// одного &#39; мало — браузер раскодирует его до запуска JS).
func TestFrontendEscapesQuotesAndUsesJsArgInHandlers(t *testing.T) {
	b, err := os.ReadFile("frontend/index.html")
	if err != nil {
		t.Fatal(err)
	}
	html := string(b)

	var escLine string
	for _, l := range strings.Split(html, "\n") {
		if strings.HasPrefix(l, "const esc = ") {
			escLine = l
		}
	}
	if escLine == "" {
		t.Fatal("не нашёл определение esc в index.html")
	}
	for _, want := range []string{`&quot;`, `&#39;`, `&lt;`, `&gt;`, `&amp;`} {
		if !strings.Contains(escLine, want) {
			t.Errorf("esc не экранирует %s", want)
		}
	}
	if !strings.Contains(html, "const jsArg = ") {
		t.Error("нет jsArg — строки в inline-обработчиках нечем безопасно вставлять")
	}

	// в обработчиках (onclick="…") строку нельзя вставлять как '${esc(…)}' — только ${jsArg(…)}
	risky := regexp.MustCompile(`on[a-z]+="[^"\n]*'\$\{esc\(`)
	for _, m := range risky.FindAllString(html, -1) {
		t.Errorf("небезопасная вставка в обработчик (используй jsArg): %.120s", m)
	}
}
