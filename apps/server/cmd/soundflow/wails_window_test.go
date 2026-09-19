package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/go-chi/chi/v5"
	wailsserver "github.com/wailsapp/wails/v2/pkg/assetserver"
	"github.com/wailsapp/wails/v2/pkg/assetserver/webview"
	wailsopts "github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

// Запрос «из окна» пропускаем через НАСТОЯЩИЙ код Wails (pkg/assetserver, ServeWebViewRequest) — тот, что в
// программе стоит между окном WebView2 и нашим APIRouter(). Он сам подписывает запрос заглушкой 192.0.2.1:1234
// (Alex TG 20090: «запрос пришёл с 192.0.2.1»). Настоящее окно из теста не открыть, но остальной путь — тот же.

type wailsLog struct{}

func (wailsLog) Debug(string, ...interface{}) {}
func (wailsLog) Error(string, ...interface{}) {}

type wailsRuntime struct{}

func (wailsRuntime) DesktopIPC() []byte       { return nil }
func (wailsRuntime) WebsocketIPC() []byte     { return nil }
func (wailsRuntime) RuntimeDesktopJS() []byte { return nil }

// fakeWebViewReq — запрос так, как его отдаёт WebView2 (адреса у него нет вообще).
type fakeWebViewReq struct {
	method, uri, body string
	rw                *fakeWebViewRW
	done              chan struct{}
}

func (f *fakeWebViewReq) URL() (string, error)    { return f.uri, nil }
func (f *fakeWebViewReq) Method() (string, error) { return f.method, nil }
func (f *fakeWebViewReq) Header() (http.Header, error) {
	h := http.Header{}
	if f.body != "" {
		h.Set("Content-Type", "application/json")
	}
	return h, nil
}
func (f *fakeWebViewReq) Body() (io.ReadCloser, error) {
	return io.NopCloser(strings.NewReader(f.body)), nil
}
func (f *fakeWebViewReq) Response() webview.ResponseWriter { return f.rw }
func (f *fakeWebViewReq) Close() error                     { close(f.done); return nil }

type fakeWebViewRW struct{ *httptest.ResponseRecorder }

func (fakeWebViewRW) Finish() error { return nil }

// viaWails отправляет запрос через настоящий AssetServer Wails с переданным обработчиком и возвращает код ответа.
// Параметры сборки те же, что в main.go: статика из fs.FS + Handler.
func viaWails(t *testing.T, handler http.Handler, method, uri, body string) int {
	t.Helper()
	srv, err := wailsserver.NewAssetServer("", wailsopts.Options{
		Assets:  fstest.MapFS{"index.html": &fstest.MapFile{Data: []byte("<html></html>")}},
		Handler: handler,
	}, false, wailsLog{}, wailsRuntime{})
	if err != nil {
		t.Fatal(err)
	}
	req := &fakeWebViewReq{method: method, uri: uri, body: body,
		rw: &fakeWebViewRW{httptest.NewRecorder()}, done: make(chan struct{})}
	srv.ServeWebViewRequest(req)
	select {
	case <-req.done:
	case <-time.After(10 * time.Second):
		t.Fatal("Wails не ответил на запрос за 10 секунд")
	}
	return req.rw.Code
}

func TestLocalOnlyThroughRealWailsAssetServer(t *testing.T) {
	e := ctxFixture(t)
	const body = `{"artist":"A","title":"B"}`

	if c := viaWails(t, e.s.APIRouter(), "POST", "/api/discover/dismiss", body); c != http.StatusOK {
		t.Errorf("окно (через настоящий AssetServer Wails) → «только с этого компьютера»: ждали 200, получили %d", c)
	}
	if c := viaWails(t, e.s.APIRouter(), "GET", "/api/yandex/preview?id=1", ""); c == http.StatusForbidden {
		t.Errorf("слушание из окна отбито защитой (403)")
	}

	// Контроль: тот же запрос Wails, но на роутере БЕЗ метки окна (как телефонный сервер) — обязан получить 403.
	// Без этого тест не доказывал бы, что решает именно метка, а не что-то другое.
	phone := chi.NewRouter()
	e.s.mountAPI(phone)
	if c := viaWails(t, phone, "POST", "/api/discover/dismiss", body); c != http.StatusForbidden {
		t.Errorf("роутер без метки окна пустил заглушку 192.0.2.1: ждали 403, получили %d", c)
	}
}
