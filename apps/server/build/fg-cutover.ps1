# fg-cutover.ps1 - switch the live SoundFlow server on fg from the old
# D:\soundflow2\srv.exe (Go + Postgres + Python sidecar) to the new headless
# soundflow-srv.exe (SQLite + ONNX in-process).
#
# RUN ON fg, elevated. The old srv.exe and Postgres are NOT removed - roll back
# with fg-rollback.ps1.
#
# ASCII-only on purpose: this file is fetched over ssh -> cmd -> powershell and
# a non-ASCII codepage there corrupts Cyrillic string literals and breaks parsing.
#
# Order:
#   1. run with -DryRun     -> check preconditions, change nothing
#   2. put new files in -SrcDir (soundflow-srv.exe, onnxruntime.dll,
#      cnn14.onnx, cnn14.onnx.data, ffmpeg.exe, soundflow.db)
#   3. run with no flags     -> switch (asks to confirm)
#   4. check the phone
#   5. if wrong -> fg-rollback.ps1

[CmdletBinding()]
param(
  [string]$SrcDir     = "D:\soundflow-srv-incoming",
  [string]$AppDir     = "D:\soundflow-srv",
  [string]$AudioRoot  = "D:\SoundFlow",
  [string]$Addr       = "0.0.0.0:8090",
  [string]$SidecarURL = "http://127.0.0.1:8001",
  [switch]$DryRun,
  [switch]$Yes
)
$ErrorActionPreference = "Stop"
function Say($m){ Write-Host "[cutover] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[cutover] $m" -ForegroundColor Yellow }

$need = @("soundflow-srv.exe","onnxruntime.dll","cnn14.onnx","cnn14.onnx.data","soundflow.db")
Say "check files in $SrcDir"
$missing = @($need | Where-Object { -not (Test-Path (Join-Path $SrcDir $_)) })
if ($missing.Count -gt 0) { throw "missing in ${SrcDir}: $($missing -join ', ')" }
$dbSize = [math]::Round((Get-Item (Join-Path $SrcDir "soundflow.db")).Length/1MB)
Say "soundflow.db = $dbSize MB"

Say "check ffmpeg with libsoxr"
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
$ffLocal = Join-Path $SrcDir "ffmpeg.exe"
if (Test-Path $ffLocal) { $ff = $ffLocal }
if (-not $ff) { throw "no ffmpeg (PATH or $SrcDir) - new server cannot fingerprint new tracks" }
$soxr = & $ff -hide_banner -buildconf 2>&1 | Select-String -SimpleMatch 'libsoxr'
if (-not $soxr) { throw "ffmpeg ($ff) built without libsoxr" }
Say "ffmpeg ok: $ff"

Say "old server now:"
$oldTask = Get-ScheduledTask -TaskName SoundFlow2 -ErrorAction SilentlyContinue
$oldProc = Get-Process srv -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "D:\soundflow2\*" }
Say ("  task SoundFlow2       : " + $(if($oldTask){$oldTask.State}else{'NONE'}))
Say ("  srv.exe (:8090)       : " + $(if($oldProc){'PID '+$oldProc.Id}else{'not running'}))
$wd = Get-ScheduledTask -TaskName soundflow-watchdog -ErrorAction SilentlyContinue
Say ("  task soundflow-watchdog: " + $(if($wd){$wd.State}else{'NONE'}))
try { $h = Invoke-RestMethod "http://127.0.0.1:8090/v1/health" -TimeoutSec 5; Say ("  old /v1/health        : " + ($h | ConvertTo-Json -Compress)) } catch { Say "  old /v1/health        : no response" }

if ($DryRun) { Say "DryRun - preconditions ok, nothing changed."; return }

if (-not $Yes) {
  $a = Read-Host "Switch the live server on fg. Old one stays for rollback. Continue? (yes)"
  if ($a -ne "yes") { Warn "cancelled"; return }
}

# 1. watchdog: disable so it does not spam Alex with alerts during the switch
if ($wd) { Say "disable task soundflow-watchdog"; Disable-ScheduledTask soundflow-watchdog | Out-Null }

# 2. stop the old server
if ($oldTask -and $oldTask.State -eq "Running") { Say "stop task SoundFlow2"; Stop-ScheduledTask SoundFlow2 }
Say "wait for :8090 to free (up to 20s)"
for ($i=1; $i -le 20; $i++) {
  Start-Sleep 1
  $busy = Get-NetTCPConnection -LocalPort 8090 -State Listen -ErrorAction SilentlyContinue
  if (-not $busy) { break }
  if ($i -eq 20) {
    Warn "port still busy - killing srv.exe"
    Get-Process srv -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "D:\soundflow2\*" } | Stop-Process -Force
    Start-Sleep 2
  }
}

# 3. lay down the new server
Say "prepare $AppDir"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if (Test-Path (Join-Path $AppDir "soundflow.db")) {
  $bak = Join-Path $AppDir ("soundflow.db.bak-" + (Get-Date -Format "yyyyMMdd-HHmm"))
  Say "backup previous $AppDir\soundflow.db -> $bak"
  Move-Item (Join-Path $AppDir "soundflow.db") $bak -Force
}
foreach ($f in @("soundflow-srv.exe","onnxruntime.dll","cnn14.onnx","cnn14.onnx.data","soundflow.db")) {
  Copy-Item (Join-Path $SrcDir $f) (Join-Path $AppDir $f) -Force
}
if (Test-Path (Join-Path $SrcDir "ffmpeg.exe")) {
  Copy-Item (Join-Path $SrcDir "ffmpeg.exe") (Join-Path $AppDir "ffmpeg.exe") -Force
}

$runCmd = @"
@echo off
set SOUNDFLOW_DB=$AppDir\soundflow.db
set SOUNDFLOW_ASSETS=$AppDir
set SOUNDFLOW_ADDR=$Addr
set SOUNDFLOW_AUDIO_ROOT=$AudioRoot
set SOUNDFLOW_SIDECAR_URL=$SidecarURL
set PATH=$AppDir;%PATH%
cd /d $AppDir
soundflow-srv.exe 1>>$AppDir\srv.log 2>&1
"@
Set-Content -Path (Join-Path $AppDir "run.cmd") -Value $runCmd -Encoding ASCII
Say "run.cmd written"

# 4. scheduled task for the new server (like SoundFlow2: at boot, SYSTEM, highest)
$taskName = "SoundFlowSrv"
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask $taskName -Confirm:$false }
$action  = New-ScheduledTaskAction -Execute (Join-Path $AppDir "run.cmd")
$trigger = New-ScheduledTaskTrigger -AtStartup
$princ   = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $princ -Settings $set | Out-Null
Say "task $taskName created"

# 5. start + check
Say "start $taskName"
Start-ScheduledTask $taskName
$ok = $false
for ($i=1; $i -le 25; $i++) {
  Start-Sleep 1
  try {
    $h = Invoke-RestMethod "http://127.0.0.1:8090/v1/health" -TimeoutSec 3
    Say ("new /v1/health: " + ($h | ConvertTo-Json -Compress))
    $ok = $true; break
  } catch {}
}
if (-not $ok) {
  Warn "new server did not answer on :8090 in 25s. See $AppDir\srv.log. Rollback: fg-rollback.ps1"
  return
}

try {
  $st = Invoke-RestMethod "http://127.0.0.1:8090/v1/admin/status" -TimeoutSec 5
  Say ("admin/status: tracks=" + $st.catalog.tracks + " devices=" + $st.devices + " disk.free_gb=" + [math]::Round($st.disk.free_bytes/1GB))
} catch { Warn "admin/status check failed: $_" }

Say "DONE. Old server and Postgres are in place (rollback: fg-rollback.ps1)."
Say "soundflow-watchdog left DISABLED - re-enable after the phone check:"
Say "  Enable-ScheduledTask soundflow-watchdog"
Say "Python sidecar (soundflow-sidecar) NOT touched - new server calls it for"
Say "'Add music'. Trimming Python (torch/youtube/soundcloud/soulseek) is a"
Say "separate later step, once the new server is proven."
