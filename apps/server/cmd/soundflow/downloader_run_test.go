package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

func TestSidecarEnvPort(t *testing.T) {
	cases := []struct {
		env         string
		port        int
		local, set  bool
		description string
	}{
		{"", 0, false, false, "не задана"},
		{"http://127.0.0.1:8001", 8001, true, true, "локальный адрес с портом"},
		{"http://localhost:8123/", 8123, true, true, "localhost"},
		{"http://192.168.1.5:8001", 0, false, true, "чужой компьютер"},
		{"http://127.0.0.1", 0, false, true, "без порта"},
		{"://мусор", 0, false, true, "не адрес"},
	}
	for _, c := range cases {
		t.Setenv("SOUNDFLOW_SIDECAR_URL", c.env)
		port, local, set := sidecarEnvPort()
		if port != c.port || local != c.local || set != c.set {
			t.Errorf("%s (%q): получил port=%d local=%v set=%v, ждал %d %v %v", c.description, c.env, port, local, set, c.port, c.local, c.set)
		}
	}
}

// Качалка на нужном порту уже отвечает (запущена вручную) — менеджер её принимает, вторую не запускает
// (python у него пустой: попытка запуска упала бы), и отпускает, когда она пропала.
func TestDownloaderAdoptsRunningSidecar(t *testing.T) {
	var alive atomic.Bool
	alive.Store(true)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" && alive.Load() {
			_, _ = w.Write([]byte(`{"status":"ok"}`))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	_, portStr, _ := net.SplitHostPort(srv.Listener.Addr().String())
	port, _ := strconv.Atoi(portStr)

	d := &downloaderProc{fixedPort: port, stop: make(chan struct{})}
	done := make(chan error, 1)
	go func() { done <- d.startOnce() }()

	deadline := time.Now().Add(3 * time.Second)
	for d.URL() == "" && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if got, want := d.URL(), "http://127.0.0.1:"+portStr; got != want {
		t.Fatalf("URL() = %q, ждал %q", got, want)
	}

	alive.Store(false) // качалка пропала — менеджер должен это заметить (проверка раз в 5 с)
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("startOnce вернул ошибку: %v", err)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("менеджер не заметил, что качалка пропала")
	}
}

func TestDownloaderStopWhileAdopted(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok")) }))
	defer srv.Close()
	_, portStr, _ := net.SplitHostPort(srv.Listener.Addr().String())
	port, _ := strconv.Atoi(portStr)
	d := &downloaderProc{fixedPort: port, stop: make(chan struct{})}
	done := make(chan error, 1)
	go func() { done <- d.startOnce() }()
	for i := 0; i < 100 && d.URL() == ""; i++ {
		time.Sleep(20 * time.Millisecond)
	}
	d.shutdown()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("после shutdown менеджер не вышел")
	}
	if !healthOnce(port) {
		t.Error("чужую (не нашу) качалку при выходе гасить нельзя")
	}
}

// Без папки качалки и без адреса ничего не запускается (как раньше).
func TestSidecarURLWithoutManagedDownloader(t *testing.T) {
	t.Setenv("SOUNDFLOW_SIDECAR_URL", "http://127.0.0.1:8001")
	s := &Service{}
	if got := s.sidecarURL(); got != "http://127.0.0.1:8001" {
		t.Errorf("без s.dl адрес берётся из окружения, получил %q", got)
	}
	// есть s.dl, но качалка ещё не ответила — «пока нет», а не адрес, по которому никто не слушает
	s.dl = &downloaderProc{fixedPort: 8001, stop: make(chan struct{})}
	if got := s.sidecarURL(); got != "" {
		t.Errorf("пока качалка не готова, адреса быть не должно, получил %q", got)
	}
}
