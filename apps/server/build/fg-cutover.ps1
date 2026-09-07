# fg-cutover.ps1 — переключение боевого сервера SoundFlow на fg со старого
# D:\soundflow2\srv.exe (Go + Postgres + Python-сайдкар) на новый headless
# soundflow-srv.exe (SQLite + ONNX в процессе).
#
# ЗАПУСКАТЬ НА fg, от админа. Старый сервер и Postgres НЕ удаляются — откат
# через fg-rollback.ps1.
#
# Порядок:
#   1. этот скрипт с -DryRun     — проверить предусловия, ничего не менять
#   2. положить файлы в -SrcDir  (soundflow-srv.exe, onnxruntime.dll,
#      cnn14.onnx, cnn14.onnx.data, soundflow.db)
#   3. этот скрипт без флагов     — переключить (спросит подтверждение)
#   4. Alex проверяет телефон через vdsmusic.ru
#   5. не так — fg-rollback.ps1

[CmdletBinding()]
param(
  [string]$SrcDir   = "D:\soundflow-srv-incoming",  # куда положены новые файлы
  [string]$AppDir   = "D:\soundflow-srv",           # рабочая папка нового сервера
  [string]$AudioRoot  = "D:\SoundFlow",             # E:\soundflow-data -> сюда
  [string]$Addr       = "0.0.0.0:8090",
  [string]$SidecarURL = "http://127.0.0.1:8001",    # Python-качалка, оставляем как есть
  [switch]$DryRun,
  [switch]$Yes
)
$ErrorActionPreference = "Stop"
function Say($m){ Write-Host "[cutover] $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "[cutover] $m" -ForegroundColor Yellow }

$need = @("soundflow-srv.exe","onnxruntime.dll","cnn14.onnx","cnn14.onnx.data","soundflow.db")
Say "проверка файлов в $SrcDir"
$missing = $need | Where-Object { -not (Test-Path (Join-Path $SrcDir $_)) }
if ($missing) { throw "нет файлов в ${SrcDir}: $($missing -join ', ')" }
$dbSize = [math]::Round((Get-Item (Join-Path $SrcDir "soundflow.db")).Length/1MB)
Say "soundflow.db = $dbSize МБ"

Say "проверка ffmpeg с libsoxr"
$ff = (Get-Command ffmpeg -EA SilentlyContinue).Source
if (-not $ff) { throw "ffmpeg не в PATH на fg — новый сервер не сможет считать отпечаток новых треков" }
$soxr = & ffmpeg -hide_banner -buildconf 2>&1 | Select-String -SimpleMatch 'libsoxr'
if (-not $soxr) { throw "ffmpeg в PATH ($ff) собран без libsoxr" }
Say "ffmpeg: $ff (libsoxr есть)"

Say "старый сервер сейчас:"
$oldTask = Get-ScheduledTask -TaskName SoundFlow2 -EA SilentlyContinue
$oldProc = Get-Process srv -EA SilentlyContinue | Where-Object { $_.Path -like "D:\soundflow2\*" }
"  task SoundFlow2      : $(if($oldTask){$oldTask.State}else{'НЕТ'})"
"  srv.exe (:8090)      : $(if($oldProc){'PID '+$oldProc.Id}else{'не запущен'})"
$wd = Get-ScheduledTask -TaskName soundflow-watchdog -EA SilentlyContinue
"  task soundflow-watchdog: $(if($wd){$wd.State}else{'НЕТ'})"
try { $h = Invoke-RestMethod "http://127.0.0.1:8090/v1/health" -TimeoutSec 5; "  старый /v1/health   : $($h | ConvertTo-Json -Compress)" } catch { "  старый /v1/health   : нет ответа" }

if ($DryRun) { Say "DryRun — предусловия ок, ничего не менял."; return }

if (-not $Yes) {
  $a = Read-Host "Переключаю боевой сервер на fg. Старый останется для отката. Продолжить? (yes)"
  if ($a -ne "yes") { Warn "отменено"; return }
}

# --- 1. сторож: отключить, чтобы не заспамил Alex алертами во время переключения
if ($wd) { Say "отключаю задачу soundflow-watchdog"; Disable-ScheduledTask soundflow-watchdog | Out-Null }

# --- 2. остановить старый сервер
if ($oldTask -and $oldTask.State -eq "Running") { Say "стоп задачи SoundFlow2"; Stop-ScheduledTask SoundFlow2 }
Say "жду освобождения :8090 (до 20 с)"
1..20 | ForEach-Object {
  Start-Sleep 1
  $busy = Get-NetTCPConnection -LocalPort 8090 -State Listen -EA SilentlyContinue
  if (-not $busy) { return }
  if ($_ -eq 20) {
    Warn "порт всё ещё занят — глушу srv.exe принудительно"
    Get-Process srv -EA SilentlyContinue | Where-Object { $_.Path -like "D:\soundflow2\*" } | Stop-Process -Force
  }
}

# --- 3. разложить новый сервер
Say "готовлю $AppDir"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if (Test-Path (Join-Path $AppDir "soundflow.db")) {
  $bak = Join-Path $AppDir ("soundflow.db.bak-" + (Get-Date -Format "yyyyMMdd-HHmm"))
  Say "бэкап прежней $AppDir\soundflow.db -> $bak"
  Move-Item (Join-Path $AppDir "soundflow.db") $bak -Force
}
$need | ForEach-Object { Copy-Item (Join-Path $SrcDir $_) (Join-Path $AppDir $_) -Force }

$runCmd = @"
@echo off
set SOUNDFLOW_DB=$AppDir\soundflow.db
set SOUNDFLOW_ASSETS=$AppDir
set SOUNDFLOW_ADDR=$Addr
set SOUNDFLOW_AUDIO_ROOT=$AudioRoot
rem sidecar не трогаем на этом шаге — новый сервер зовёт его как есть
set SOUNDFLOW_SIDECAR_URL=$SidecarURL
cd /d $AppDir
soundflow-srv.exe 1>>$AppDir\srv.log 2>&1
"@
Set-Content -Path (Join-Path $AppDir "run.cmd") -Value $runCmd -Encoding ASCII
Say "run.cmd записан"

# --- 4. задача планировщика для нового сервера (как SoundFlow2: при загрузке, SYSTEM, Highest)
$taskName = "SoundFlowSrv"
if (Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue) { Unregister-ScheduledTask $taskName -Confirm:$false }
$action  = New-ScheduledTaskAction -Execute (Join-Path $AppDir "run.cmd")
$trigger = New-ScheduledTaskTrigger -AtStartup
$princ   = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $princ -Settings $set | Out-Null
Say "задача $taskName создана"

# --- 5. старт + проверка
Say "старт $taskName"
Start-ScheduledTask $taskName
$ok = $false
1..25 | ForEach-Object {
  Start-Sleep 1
  try {
    $h = Invoke-RestMethod "http://127.0.0.1:8090/v1/health" -TimeoutSec 3
    Say "новый /v1/health: $($h | ConvertTo-Json -Compress)"
    $ok = $true; return
  } catch {}
}
if (-not $ok) {
  Warn "новый сервер не ответил на :8090 за 25 с. Смотри $AppDir\srv.log. Откат: fg-rollback.ps1"
  return
}

Say "ГОТОВО. Старый сервер и Postgres на месте (откат — fg-rollback.ps1)."
Say "Сторож soundflow-watchdog оставлен ОТКЛЮЧЁННЫМ — включить после проверки телефона:"
Say "  Enable-ScheduledTask soundflow-watchdog"
Say "Python-сайдкар (soundflow-sidecar) НЕ трогали — новый сервер зовёт его для"
Say "«Добавить музыку». Урезание питона (torch/youtube/soundcloud/soulseek) —"
Say "отдельным шагом позже, когда новый сервер обкатан."
