package config

import (
	"os"
)

// Config — настройки сервера из переменных окружения.
// На этапе каркаса всё простое; хеш пароля и прочее приедут своим шагом.
type Config struct {
	Addr        string // на чём слушать, напр. ":8090"
	AdminLogin  string // единственный пользователь — Alex
	AdminPass   string // пароль (пока в открытую в env; станет bcrypt-хешем)
	JWTSecret   []byte // ключ подписи пропуска
	DatabaseURL string // строка подключения к PostgreSQL
	MusicDir    string // папка с тестовой музыкой; пусто — отдаём сгенерированный тон
}

func Load() Config {
	return Config{
		Addr:        env("SOUNDFLOW_ADDR", ":8090"),
		AdminLogin:  env("SOUNDFLOW_ADMIN_LOGIN", "alex"),
		AdminPass:   env("SOUNDFLOW_ADMIN_PASSWORD", "change-me"),
		JWTSecret:   []byte(env("SOUNDFLOW_JWT_SECRET", "dev-secret-change-me")),
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
