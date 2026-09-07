# fg-rollback.ps1 - revert the live SoundFlow server on fg back to the old
# D:\soundflow2\srv.exe. Undo of fg-cutover.ps1. Removes nothing from the new
# setup - just stops the new server and brings the old one back up.
#
# RUN ON fg, elevated. ASCII-only on purpose (ssh -> cmd -> powershell codepage).

[CmdletBinding()]
param([switch]$Yes)
$ErrorActionPreference = "Stop"
function Say($m){ Write-Host "[rollback] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[rollback] $m" -ForegroundColor Yellow }

if (-not $Yes) {
  $a = Read-Host "Rollback: stop new soundflow-srv, bring back old SoundFlow2. Continue? (yes)"
  if ($a -ne "yes") { Warn "cancelled"; return }
}

# 1. stop the new one
$new = Get-ScheduledTask -TaskName SoundFlowSrv -ErrorAction SilentlyContinue
if ($new) {
  Say "stop task SoundFlowSrv"
  Stop-ScheduledTask SoundFlowSrv -ErrorAction SilentlyContinue
  Disable-ScheduledTask SoundFlowSrv | Out-Null
}
Get-Process soundflow-srv -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2

# 2. start the old one
Say "start task SoundFlow2"
Start-ScheduledTask SoundFlow2
$ok = $false
for ($i=1; $i -le 25; $i++) {
  Start-Sleep 1
  try { $h = Invoke-RestMethod "http://127.0.0.1:8090/v1/health" -TimeoutSec 3; Say ("old /v1/health: " + ($h | ConvertTo-Json -Compress)); $ok = $true; break } catch {}
}
if (-not $ok) { Warn "old server did not answer in 25s - see D:\soundflow2\srv.log" }

# 3. watchdog back on
$wd = Get-ScheduledTask -TaskName soundflow-watchdog -ErrorAction SilentlyContinue
if ($wd) { Say "enable soundflow-watchdog"; Enable-ScheduledTask soundflow-watchdog | Out-Null }

Say "rollback done. New soundflow.db and exe stay in D:\soundflow-srv (not removed)."
