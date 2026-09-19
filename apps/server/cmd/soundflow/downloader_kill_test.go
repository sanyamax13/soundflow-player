package main

import (
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// У venv на Windows python.exe — прокладка, настоящий интерпретатор идёт дочерним. killProcessTree
// должен убивать и потомков, иначе качалка пережила бы закрытие программы. Здесь то же самое на
// безопасной паре «cmd → ping» (свои процессы, ничего чужого не трогаем).
func TestKillProcessTreeKillsChildren(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("дерево процессов проверяем только на Windows")
	}
	cmd := exec.Command("cmd.exe", "/c", "ping -n 60 127.0.0.1 > nul")
	hideChildWindow(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	parent := cmd.Process.Pid
	waitDone := make(chan struct{})
	go func() { _ = cmd.Wait(); close(waitDone) }()

	var childPID string
	for i := 0; i < 20 && childPID == ""; i++ {
		time.Sleep(200 * time.Millisecond)
		out, _ := exec.Command("powershell", "-NoProfile", "-Command",
			"(Get-CimInstance Win32_Process -Filter 'ParentProcessId="+strconv.Itoa(parent)+"' | Select-Object -First 1).ProcessId").Output()
		childPID = strings.TrimSpace(string(out))
	}
	if childPID == "" {
		killProcessTree(parent)
		t.Fatal("не нашёл дочерний процесс у cmd.exe — тест не может проверить дерево")
	}

	killProcessTree(parent)
	select {
	case <-waitDone:
	case <-time.After(5 * time.Second):
		t.Fatal("родительский процесс не завершился")
	}
	time.Sleep(300 * time.Millisecond)
	out, _ := exec.Command("tasklist", "/FI", "PID eq "+childPID, "/NH").Output()
	if strings.Contains(string(out), "ping.exe") {
		t.Errorf("дочерний ping.exe (PID %s) остался жить после killProcessTree", childPID)
		_ = exec.Command("taskkill", "/F", "/PID", childPID).Run()
	}
}
