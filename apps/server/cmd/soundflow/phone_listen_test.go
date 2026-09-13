package main

import (
	"net"
	"strconv"
	"testing"
)

// TestListenWithFallbackTakesNextFreePort — Опус-ревью 14.09.2026, пункт 1:
// настроенный порт занят другой программой (как TorrServer занял 8090 у
// Alex) — должны молча не падать, а встать на следующий свободный и честно
// сообщить, на каком именно.
func TestListenWithFallbackTakesNextFreePort(t *testing.T) {
	busy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("занять тестовый порт: %v", err)
	}
	defer busy.Close()
	busyAddr := busy.Addr().(*net.TCPAddr)

	ln, boundAddr, err := listenWithFallback("127.0.0.1:"+strconv.Itoa(busyAddr.Port), maxPortFallbackTries)
	if err != nil {
		t.Fatalf("listenWithFallback: %v", err)
	}
	defer ln.Close()

	if boundAddr == "127.0.0.1:"+strconv.Itoa(busyAddr.Port) {
		t.Fatalf("должен был откатиться на другой порт, а встал на занятый: %s", boundAddr)
	}
	got := ln.Addr().(*net.TCPAddr)
	if got.Port <= busyAddr.Port || got.Port > busyAddr.Port+maxPortFallbackTries {
		t.Fatalf("ожидал порт в диапазоне (%d, %d], получил %d", busyAddr.Port, busyAddr.Port+maxPortFallbackTries, got.Port)
	}
}

func TestListenWithFallbackFreePortStaysOnIt(t *testing.T) {
	// Найти заведомо свободный порт: открыть и сразу закрыть.
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("найти свободный порт: %v", err)
	}
	freeAddr := probe.Addr().String()
	probe.Close()

	ln, boundAddr, err := listenWithFallback(freeAddr, maxPortFallbackTries)
	if err != nil {
		t.Fatalf("listenWithFallback: %v", err)
	}
	defer ln.Close()
	if boundAddr != freeAddr {
		t.Fatalf("порт был свободен, но встали не на него: хотели %s, получили %s", freeAddr, boundAddr)
	}
}

func TestListenWithFallbackAllPortsBusy(t *testing.T) {
	// Занимаем N портов подряд начиная с случайного свободного, чтобы
	// исчерпать весь диапазон фолбэка.
	first, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("занять первый порт: %v", err)
	}
	defer first.Close()
	startPort := first.Addr().(*net.TCPAddr).Port

	var busies []net.Listener
	for i := 1; i < maxPortFallbackTries; i++ {
		l, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(startPort+i))
		if err != nil {
			t.Skipf("не смог занять весь диапазон для теста (окружение): %v", err)
		}
		busies = append(busies, l)
	}
	defer func() {
		for _, l := range busies {
			l.Close()
		}
	}()

	_, _, err = listenWithFallback("127.0.0.1:"+strconv.Itoa(startPort), maxPortFallbackTries)
	if err == nil {
		t.Fatal("ожидал ошибку — весь диапазон занят, а получили успех")
	}
}

