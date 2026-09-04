package config

import (
	"os"
)

// Config — настройки сервера из переменных окружения.
// Входа/пароля нет: плеер личный, сервер живёт в домашней сети (решение Alex
// 04.09.2026). Понадобится доступ снаружи — вернём токен.
type Config struct {
	Addr        string // на чём слушать, напр. ":8090"
	DatabaseURL string // строка подключения к PostgreSQL
	MusicDir    string // папка с тестовой музыкой; пусто — отдаём сгенерированный тон
}

func Load() Config {
	return Config{
		Addr:        env("SOUNDFLOW_ADDR", ":8090"),
		DatabaseURL: env("DATABASE_URL", "postgres://soundflow:soundflow_dev@localhost:5433/soundflow?sslmode=disable"),
		MusicDir:    env("SOUNDFLOW_MUSIC_DIR", ""),
	}
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
