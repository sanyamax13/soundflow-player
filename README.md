# SoundFlow

Личный офлайн-плеер. Чистый проект: телефон на Flutter, сервер на Go.
Начат 04.09.2026 после ревизии переезда (старая веб-версия — в `e:\music-player`,
только как справочник).

```
apps/
  mobile/    — приложение (Flutter, только Android)
  server/    — сервер (Go): выдача музыки, Поток, чарты, синхронизация
docs/        — план переезда и продуктовые правила (перенесены из старого проекта)
docker-compose.yml — PostgreSQL для сервера (порт 5433)
```

## Запуск (разработка)

Сервер:
```
cd apps/server
copy ..\..\.env.example ..\..\.env   # заполнить пароль и ключ
go run ./cmd/soundflow-server         # слушает :8090
```
База (нужен Docker):
```
docker compose up -d
```

Приложение:
```
cd apps/mobile
flutter run
```

## Состояние

Этап 1 (каркас) — в работе. Дальше по `docs/SOUNDFLOW_FLUTTER_GO_MIGRATION_PLAN.md` §9.
