package main

import (
	"crypto/rand"
	"encoding/hex"
	"net"
)

// hostIP — IPv4 этой машины в ДОМАШНЕЙ сети (для строки адреса в окне —
// её вписывают в телефон). Предпочитаем 192.168.* / 10.* / 172.16-31.*;
// адреса Tailscale (100.64.0.0/10 CGNAT) и прочее — только если ничего
// другого нет.
func hostIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	var lan, other string
	for _, a := range addrs {
		ipn, ok := a.(*net.IPNet)
		if !ok || ipn.IP.IsLoopback() {
			continue
		}
		v4 := ipn.IP.To4()
		if v4 == nil {
			continue
		}
		s := v4.String()
		if isHomeLAN(v4) {
			if lan == "" {
				lan = s
			}
		} else if !isCGNAT(v4) && other == "" {
			other = s
		}
	}
	if lan != "" {
		return lan
	}
	return other
}

func isHomeLAN(ip net.IP) bool {
	return ip[0] == 192 && ip[1] == 168 ||
		ip[0] == 10 ||
		ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31
}

// isCGNAT — 100.64.0.0/10 (сюда попадает Tailscale).
func isCGNAT(ip net.IP) bool {
	return ip[0] == 100 && ip[1] >= 64 && ip[1] <= 127
}

func randHex() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
