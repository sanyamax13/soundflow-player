# Деплой Go-сервера на fg

fg — домашний сервер (Windows 10, `ssh soundflow-fg`). Там же живёт старый
Python-сайдкар (`:8001`) и физически лежит музыка (`D:\SoundFlow\`).
Сервер должен крутиться на fg, иначе не сможет отдать файлы с диска.

## Что где

| Что | Путь / имя |
|---|---|
| Бинарь | `D:\soundflow2\srv.exe` |
| Запуск + env | `D:\soundflow2\run.cmd` (пароль базы внутри, в git НЕ кладём) |
| Лог | `D:\soundflow2\srv.log` |
| База | docker `soundflow2-postgres`, `pgvector/pgvector:pg17`, `127.0.0.1:5434`, том `soundflow2_pgdata` |
| Автозапуск | задача планировщика `SoundFlow2` (`onstart`, задержка 2 мин, от SYSTEM) |
| Порт | `0.0.0.0:8090`, правило файрвола `SoundFlow2-8090` |

Старую базу `soundflow-postgres` (`:5432`) и сайдкар НЕ трогаем.

## Обновить бинарь

С brain, из `apps/server`:

```bash
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
  -o /tmp/srv.exe ./cmd/soundflow-server
scp /tmp/srv.exe soundflow-fg:'D:\soundflow2\srv.exe'
ssh soundflow-fg 'schtasks /end /tn SoundFlow2 & timeout /t 2 & schtasks /run /tn SoundFlow2'
```

(`srv.exe` занят, пока сервер жив — сперва `schtasks /end`.)

## Первичная настройка (уже сделана 04.09.2026)

```bash
# база
ssh soundflow-fg 'docker run -d --name soundflow2-postgres --restart unless-stopped \
  -e POSTGRES_USER=soundflow -e POSTGRES_PASSWORD=<PW> -e POSTGRES_DB=soundflow \
  -p 127.0.0.1:5434:5432 -v soundflow2_pgdata:/var/lib/postgresql/data pgvector/pgvector:pg17'

# файрвол
ssh soundflow-fg 'netsh advfirewall firewall add rule name="SoundFlow2-8090" \
  dir=in action=allow protocol=TCP localport=8090'

# задача автозапуска
ssh soundflow-fg 'schtasks /create /tn SoundFlow2 /tr "D:\soundflow2\run.cmd" \
  /sc onstart /delay 0002:00 /ru SYSTEM /rl highest /f'
```

### run.cmd (шаблон, `<PW>` — пароль базы)

```bat
@echo off
set DATABASE_URL=postgres://soundflow:<PW>@127.0.0.1:5434/soundflow?sslmode=disable
set SOUNDFLOW_ADDR=0.0.0.0:8090
set SOUNDFLOW_SIDECAR_URL=http://127.0.0.1:8001
set SIDECAR_CANONICAL_CACHE_DIR=E:\soundflow-data\cache
set SIDECAR_LOCAL_CACHE_DIR=D:\SoundFlow\cache
set SIDECAR_CANONICAL_ALBUMS_DIR=E:\soundflow-data\music
set SIDECAR_LOCAL_ALBUMS_DIR=D:\SoundFlow\music
cd /d D:\soundflow2
srv.exe 1>>D:\soundflow2\srv.log 2>&1
```

Пути `CANONICAL`/`LOCAL` берём из `.env` сайдкара
(`D:\soundflow-app\apps\python-sidecar\.env`: `CANONICAL_CACHE_DIR` / `TRACK_CACHE_DIR`).

## Проверка

```bash
curl -s http://192.168.1.73:8090/v1/health          # {"db":"ok","status":"alive"}
ssh soundflow-fg 'type D:\soundflow2\srv.log'
```

Телефон/эмулятор: `flutter build apk --dart-define=SOUNDFLOW_API=http://192.168.1.73:8090`
(в локальной сети — реальный IP, adb reverse не нужен).

## Известные дыры

- Задача `onstart` + задержка 2 мин. Если docker не поднялся за 2 мин после
  ребута fg — сервер стартует с базой `down` и накат миграций не повторяет.
  Укрепить: ждать порт 5434 в `run.cmd` или ретрай `Migrate` в сервере.
