@echo off
rem Копия PC-приложения SoundFlow на рабочем столе (16.09.2026, по просьбе
rem Alex). Программа и её файлы (модель, ffmpeg, adb) — здесь, на рабочем
rem столе. База данных и музыка — НЕ скопированы (много гигабайт), программа
rem обращается к ним по прежнему пути на диске E:.
set SOUNDFLOW_DB=E:\soundflow-data\soundflow.db
set SOUNDFLOW_ASSETS=%~dp0
set SOUNDFLOW_ADDR=0.0.0.0:8091
set SOUNDFLOW_AUDIO_ROOT=E:\soundflow-data
set SOUNDFLOW_SIDECAR_URL=http://127.0.0.1:8001
rem Качалка (Яндекс, лайки, волна, скачивание): программа сама запускает её вместе с собой и гасит при выходе
rem (19.09.2026, по просьбе Alex). Порт берётся из SOUNDFLOW_SIDECAR_URL выше. Папка качалки:
set SOUNDFLOW_DOWNLOADER=E:\soundflow-lab\fg-sidecar-src
set SOUNDFLOW_GENERATED_COVERS_DIR=E:\soundflow-data\generated_covers
cd /d "%~dp0"
start "" "%~dp0SoundFlow.exe"
