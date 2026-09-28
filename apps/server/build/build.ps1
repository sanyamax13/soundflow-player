# Сборка релиза SoundFlow.exe + установщика.
#   pwsh apps\server\build\build.ps1
# Требует: Go (E:\go), mingw-w64 в PATH (CGo), ISCC (Inno Setup).
# Ассеты модели берёт из -AssetsDir (по умолч. E:\soundflow-lab).

param(
  [string]$AssetsDir = "E:\soundflow-lab",
  [string]$Version   = "0.1.0",
  [string]$QbtUrl    = "https://sourceforge.net/projects/qbittorrent/files/qbittorrent-win32/qbittorrent-5.2.3/qbittorrent_5.2.3_x64_setup.exe/download",
  [switch]$SkipInstaller
)
$ErrorActionPreference = "Stop"
$root  = Split-Path -Parent $PSScriptRoot         # apps\server
$build = $PSScriptRoot                            # apps\server\build
$dist  = Join-Path $build "dist"
$app   = Join-Path $dist  "app"
$redist= Join-Path $dist  "redist"
New-Item -ItemType Directory -Force -Path $app,$redist | Out-Null

Write-Host "== go build SoundFlow.exe ==" -ForegroundColor Cyan
$env:CGO_ENABLED = "1"
if (Test-Path "C:\ProgramData\mingw64\mingw64\bin") { $env:PATH = "C:\ProgramData\mingw64\mingw64\bin;$env:PATH" }
if (Test-Path "E:\go\bin") { $env:PATH = "E:\go\bin;$env:PATH" }
Push-Location $root
try {
  # Wails v2: без тегов production бинарь показывает окно-ошибку «wails applications
  # will not build without the correct build tags». desktop,production — как в
  # https://wails.io/docs/guides/manual-builds/
  go build -tags "desktop,production" -ldflags "-H windowsgui -s -w -X main.appVersion=$Version" -o (Join-Path $app "SoundFlow.exe") ./cmd/soundflow
} finally { Pop-Location }

Write-Host "== ассеты модели ==" -ForegroundColor Cyan
foreach ($f in "onnxruntime.dll","cnn14.onnx","cnn14.onnx.data") {
  Copy-Item (Join-Path $AssetsDir $f) (Join-Path $app $f) -Force
}
# soundflow.db в установщик НЕ кладём — это данные пользователя, приходят
# из soundflow-import (Postgres -> SQLite) и живут в %LocalAppData%\SoundFlow.

Write-Host "== ffmpeg.exe ==" -ForegroundColor Cyan
# ВАЖНО: нужна сборка ffmpeg С libsoxr — декод отпечатка использует
# `aresample=resampler=soxr`. Сборка "essentials" от gyan.dev soxr НЕ содержит
# (падает "Requested resampling engine is unavailable"). Берём "full" (~223 МБ)
# из $AssetsDir\ffmpeg.exe, иначе из PATH (проверь `ffmpeg -buildconf | findstr soxr`).
$ff = $null
if (Test-Path (Join-Path $AssetsDir "ffmpeg.exe")) { $ff = Join-Path $AssetsDir "ffmpeg.exe" }
if (-not $ff) { $ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source }
if (-not $ff) {
  $cand = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cand) { $ff = $cand.FullName }
}
if ($ff) { Copy-Item $ff (Join-Path $app "ffmpeg.exe") -Force; Write-Host "  ffmpeg: $ff" }
else { Write-Warning "ffmpeg.exe не найден — положи вручную в $app" }

@"
SoundFlow — каталог музыки + подбор по звуку в одном приложении.

Рядом с SoundFlow.exe: onnxruntime.dll, cnn14.onnx (+ cnn14.onnx.data), ffmpeg.exe.
База и логи: %LocalAppData%\SoundFlow\soundflow.db

Первый запуск: если базы нет, укажи папки с музыкой кнопкой «Сканировать папку».
Настройки своей копии (папка музыки, Яндекс, свой ВДС): %LocalAppData%\SoundFlow\settings.json —
обновление программы их не трогает.

Телефон: адрес из шапки окна, порт 8090.
"@ | Set-Content -Encoding UTF8 (Join-Path $app "README.txt")

Write-Host "== качалка (Яндекс, торренты) ==" -ForegroundColor Cyan
# Своя копия плеера у другого человека (28.09.2026): качалка едет в установщике целиком —
# исходники + переносной Python (python-build-standalone через uv) со всеми библиотеками внутри.
# Программа находит её в {app}\downloader и запускает python\python.exe (downloader.go).
$dlSrc = Join-Path (Split-Path -Parent $root) "downloader"   # apps\downloader
$dl    = Join-Path $app "downloader"
if (Test-Path $dl) { Remove-Item $dl -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dl | Out-Null
Copy-Item (Join-Path $dlSrc "src") (Join-Path $dl "src") -Recurse -Force
Copy-Item (Join-Path $dlSrc "pyproject.toml") $dl -Force
Get-ChildItem $dl -Recurse -Directory -Filter "__pycache__" | Remove-Item -Recurse -Force
$pyTmp = Join-Path $dist "py-standalone"
if (Test-Path $pyTmp) { Remove-Item $pyTmp -Recurse -Force }
uv python install 3.12 --install-dir $pyTmp --no-bin
if ($LASTEXITCODE -ne 0) { throw "uv python install не удался" }
$pyHome = Get-ChildItem $pyTmp -Directory | Where-Object { Test-Path (Join-Path $_.FullName "python.exe") } | Select-Object -First 1
if (-not $pyHome) { throw "переносной Python не найден в $pyTmp" }
Copy-Item $pyHome.FullName (Join-Path $dl "python") -Recurse -Force
$py = Join-Path $dl "python\python.exe"
Remove-Item (Join-Path $dl "python\Lib\EXTERNALLY-MANAGED") -Force -ErrorAction SilentlyContinue
uv pip install --python $py -r (Join-Path $dl "pyproject.toml")
if ($LASTEXITCODE -ne 0) { throw "библиотеки качалки не поставились" }
& $py -c "import fastapi, uvicorn, yandex_music, qbittorrentapi, curl_cffi; print('качалка: библиотеки на месте')"
if ($LASTEXITCODE -ne 0) { throw "проверка библиотек качалки не прошла" }

Write-Host "== редисты ==" -ForegroundColor Cyan
$vc = Join-Path $redist "vc_redist.x64.exe"
if (-not (Test-Path $vc)) {
  try { Invoke-WebRequest "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vc -UseBasicParsing } catch { Write-Warning "vc_redist не скачан: $_" }
}
$wv = Join-Path $redist "MicrosoftEdgeWebview2Setup.exe"
if (-not (Test-Path $wv)) {
  try { Invoke-WebRequest "https://go.microsoft.com/fwlink/p/?LinkId=2124703" -OutFile $wv -UseBasicParsing } catch { Write-Warning "WebView2 bootstrapper не скачан: $_" }
}

$qbt = Join-Path $redist "qbittorrent_setup.exe"
if (-not (Test-Path $qbt)) {
  try { Invoke-WebRequest $QbtUrl -OutFile $qbt -UseBasicParsing -UserAgent "Wget" } catch { Write-Warning "qBittorrent не скачан: $_" }
}

Write-Host "== состав ==" -ForegroundColor Cyan
Get-ChildItem $app | Select-Object Name,@{n="MB";e={[math]::Round($_.Length/1MB,1)}} | Format-Table -AutoSize

if ($SkipInstaller) { Write-Host "готово (без установщика): $app"; return }

Write-Host "== ISCC ==" -ForegroundColor Cyan
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) { $iscc = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" }
& $iscc "/DAppVer=$Version" (Join-Path $build "soundflow.iss")
Write-Host "готово: $dist\SoundFlow-Setup-$Version.exe" -ForegroundColor Green
