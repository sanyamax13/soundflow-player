# fg-rollback.ps1 — вернуть боевой сервер на fg к старому D:\soundflow2\srv.exe.
# Обратка к fg-cutover.ps1. Ничего не удаляет из нового — просто останавливает
# новый сервер и поднимает старый + сторож.
#
# ЗАПУСКАТЬ НА fg, от админа.

[CmdletBinding()]
param([switch]$Yes)
$ErrorActionPreference = "Stop"
function Say($m){ Write-Host "[rollback] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[rollback] $m" -ForegroundColor Yellow }

if (-not $Yes) {
  $a = Read-Host "Откат: остановить новый soundflow-srv, вернуть старый SoundFlow2. Продолжить? (yes)"
  if ($a -ne "yes") { Warn "отменено"; return }
}

# 1. стоп нового
$new = Get-ScheduledTask -TaskName SoundFlowSrv -EA SilentlyContinue
if ($new) {
  Say "стоп задачи SoundFlowSrv"
  Stop-ScheduledTask SoundFlowSrv -EA SilentlyContinue
  Disable-ScheduledTask SoundFlowSrv | Out-Null
}
Get-Process soundflow-srv -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 2

# 2. старт старого
Say "старт задачи SoundFlow2"
Start-ScheduledTask SoundFlow2
$ok = $false
1..25 | ForEach-Object {
  Start-Sleep 1
  try { $h = Invoke-RestMethod "http://127.0.0.1:8090/v1/health" -TimeoutSec 3; Say "старый /v1/health: $($h | ConvertTo-Json -Compress)"; $ok = $true; return } catch {}
}
if (-not $ok) { Warn "старый сервер не ответил за 25 с — смотри D:\soundflow2\srv.log" }

# 3. сторож обратно
$wd = Get-ScheduledTask -TaskName soundflow-watchdog -EA SilentlyContinue
if ($wd) { Say "включаю soundflow-watchdog"; Enable-ScheduledTask soundflow-watchdog | Out-Null }

# 4. сайдкар, если был остановлен
$sc = Get-Service soundflow-sidecar -EA SilentlyContinue
if ($sc -and $sc.Status -ne "Running") {
  Say "поднимаю службу soundflow-sidecar"
  Set-Service soundflow-sidecar -StartupType Automatic
  Start-Service soundflow-sidecar
}

Say "откат завершён. Новый soundflow.db и exe остались в D:\soundflow-srv (не удалял)."
