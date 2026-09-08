# fg-shutdown-rollback.ps1 - bring the SoundFlow server + sidecar on fg back up.
# Undo of fg-shutdown.ps1. Nothing was deleted, so this just re-enables and starts.
#
# RUN ON fg, elevated. ASCII-only.

[CmdletBinding()]
param([switch]$Yes, [switch]$IncludeLegacy)
$ErrorActionPreference = "Continue"
function Say($m){ Write-Host "[fg-back] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[fg-back] $m" -ForegroundColor Yellow }

if (-not $Yes) {
  $a = Read-Host "Bring SoundFlow server + sidecar on fg back up? (yes)"
  if ($a -ne "yes") { Warn "cancelled"; return }
}

$s = Get-Service soundflow-sidecar -ErrorAction SilentlyContinue
if ($s) {
  Say "start soundflow-sidecar, set Automatic"
  Set-Service soundflow-sidecar -StartupType Automatic
  Start-Service soundflow-sidecar -ErrorAction SilentlyContinue
}

$t = Get-ScheduledTask -TaskName SoundFlowSrv -ErrorAction SilentlyContinue
if ($t) {
  Say "enable + start task SoundFlowSrv"
  Enable-ScheduledTask SoundFlowSrv | Out-Null
  Start-ScheduledTask SoundFlowSrv
}

$ok = $false
for ($i=1; $i -le 25; $i++) {
  Start-Sleep 1
  try { $h = Invoke-RestMethod "http://127.0.0.1:8090/v1/health" -TimeoutSec 3; Say ("fg /v1/health: " + ($h | ConvertTo-Json -Compress)); $ok = $true; break } catch {}
}
if (-not $ok) { Warn "fg server did not answer in 25s - check D:\soundflow-srv\" }

$wd = Get-ScheduledTask -TaskName soundflow-watchdog -ErrorAction SilentlyContinue
if ($wd) { Say "enable soundflow-watchdog"; Enable-ScheduledTask soundflow-watchdog | Out-Null }

if ($IncludeLegacy) {
  foreach ($svc in "soundflow-web") {
    $x = Get-Service $svc -ErrorAction SilentlyContinue
    if ($x) { Say "start $svc Automatic"; Set-Service $svc -StartupType Automatic; Start-Service $svc -ErrorAction SilentlyContinue }
  }
  foreach ($c in "soundflow-postgres","soundflow-slskd","soundflow-bgutil-pot","soundflow2-postgres") {
    Say "docker start $c"; docker start $c 2>&1 | Out-Null
  }
}

Say "done. fg is back."
