# fg-shutdown.ps1 - turn OFF everything SoundFlow-related on fg after the phone
# has moved to the PC (brain). Reversible: stops services/tasks and disables
# autostart, DELETES NOTHING. The machine keeps running (LogicLike staging on
# the same box is untouched). Undo with fg-shutdown-rollback.ps1.
#
# PRECONDITION: brain is serving the phone on 192.168.1.104:8090 and the phone
# has been repointed there and soak-tested. Do NOT run before that.
#
# RUN ON fg, elevated. ASCII-only (ssh -> cmd -> powershell codepage).

[CmdletBinding()]
param([switch]$Yes, [switch]$IncludeLegacy)
$ErrorActionPreference = "Continue"
function Say($m){ Write-Host "[fg-off] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[fg-off] $m" -ForegroundColor Yellow }

# safety: confirm brain is actually up before killing fg's server
try {
  $h = Invoke-RestMethod "http://192.168.1.104:8090/v1/health" -TimeoutSec 4
  Say ("brain /v1/health: " + ($h | ConvertTo-Json -Compress))
} catch {
  Warn "brain (192.168.1.104:8090) did NOT answer. Refusing to shut fg down."
  Warn "Start the PC program first, then re-run."
  return
}

if (-not $Yes) {
  $a = Read-Host "Shut down SoundFlow server + sidecar on fg (reversible, no deletes). Continue? (yes)"
  if ($a -ne "yes") { Warn "cancelled"; return }
}

# 1. phone-facing server
$t = Get-ScheduledTask -TaskName SoundFlowSrv -ErrorAction SilentlyContinue
if ($t) {
  Say "stop + disable task SoundFlowSrv"
  Stop-ScheduledTask SoundFlowSrv -ErrorAction SilentlyContinue
  Disable-ScheduledTask SoundFlowSrv | Out-Null
}
Get-Process soundflow-srv -ErrorAction SilentlyContinue | Stop-Process -Force

# 2. download / fingerprint sidecar (Python, nssm service)
$s = Get-Service soundflow-sidecar -ErrorAction SilentlyContinue
if ($s) {
  Say "stop soundflow-sidecar, set to Manual"
  Stop-Service soundflow-sidecar -Force -ErrorAction SilentlyContinue
  Set-Service soundflow-sidecar -StartupType Manual
}

# 3. old Go server task (already stopped since 07.09, make sure)
$old = Get-ScheduledTask -TaskName SoundFlow2 -ErrorAction SilentlyContinue
if ($old -and $old.State -ne "Disabled") {
  Say "disable old task SoundFlow2"
  Stop-ScheduledTask SoundFlow2 -ErrorAction SilentlyContinue
  Disable-ScheduledTask SoundFlow2 | Out-Null
}

# 4. watchdog (Telegram alerts) - off so it doesn't cry about the dead server
$wd = Get-ScheduledTask -TaskName soundflow-watchdog -ErrorAction SilentlyContinue
if ($wd) { Say "disable soundflow-watchdog"; Disable-ScheduledTask soundflow-watchdog | Out-Null }

# 5. legacy stack (old bun API, its Postgres, slskd, yt-dlp POT) - only with -IncludeLegacy
if ($IncludeLegacy) {
  foreach ($svc in "soundflow-web","soundflow-api") {
    $x = Get-Service $svc -ErrorAction SilentlyContinue
    if ($x) { Say "stop $svc, Manual"; Stop-Service $svc -Force -ErrorAction SilentlyContinue; Set-Service $svc -StartupType Manual }
  }
  foreach ($c in "soundflow-postgres","soundflow-slskd","soundflow-bgutil-pot","soundflow2-postgres") {
    Say "docker stop $c"
    docker stop $c 2>&1 | Out-Null
  }
  Warn "legacy containers stopped (NOT removed). 'docker start <name>' to bring back."
} else {
  Say "legacy stack (soundflow-web, its Postgres, slskd, bgutil) LEFT RUNNING."
  Say "re-run with -IncludeLegacy once you are sure nothing needs them."
}

Say "done. fg SoundFlow server + sidecar are OFF. Nothing deleted."
Say "Rollback: .\fg-shutdown-rollback.ps1 -Yes"
