package main

import "embed"

// frontend/ (index.html в корне) вшивается в exe — Wails отдаёт статику сам.
//
//go:embed all:frontend
var assets embed.FS
