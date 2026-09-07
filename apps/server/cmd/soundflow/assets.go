package main

import "embed"

// frontend/ (index.html в корне) вшивается в exe. Нужен и оконной сборке
// (Wails отдаёт статику сам), и headless-сборке (статику отдаёт телефонный
// сервер на :8090, чтобы дашборд открывался обычным браузером).
//
//go:embed all:frontend
var assets embed.FS
