// Alex TG 14.09.2026: «возьмём моё избранное из Яндекса» — своего каталога
// почти нет (библиотеку стёрли, этап 89), а в Яндексе годы личного отбора
// (575 лайков, 339 дизлайков на момент разговора). Шаг 1: показать лайки
// списком во вкладке «Открытия», скачивать — тем же путём, что «Найти и
// скачать» (POST /api/acquire, уже умеет искать по Яндексу/торрентам и
// проверять качество). Дизлайки — молча в чёрный список (legacy_marks
// blocked), чтобы вкус-движок не подсовывал похожее на то, что Alex явно
// не любит. Никакого автоскачивания без выбора Alex — это следующий шаг,
// обсуждается отдельно.
package main

import (
	"context"
	"net/http"
	"os"
	"time"

	"soundflow/server/internal/localdb"
	"soundflow/server/internal/quality"
	"soundflow/server/internal/sidecar"
)

// sidecarURL — адрес качалки. Найдено при разборе задачи «лайки Яндекса»
// (14.09.2026): s.dl.URL() — встроенный дочерний процесс качалки,
// findDownloaderDir() ищет её ОТНОСИТЕЛЬНО рабочей папки процесса — при
// обычном запуске («Запустить SoundFlow.cmd», рабочая папка —
// soundflow-brain-app) не находит НИЧЕГО, и «Найти трек»/торренты молча не
// работают («качалка не входит в эту копию программы»). У самого .cmd уже
// год как прописана SOUNDFLOW_SIDECAR_URL (реальная качалка —
// E:\soundflow-lab\fg-sidecar-src, порт 8001, отдельный процесс) — просто
// в Go-коде её никто не читал. Теперь: сперва эта переменная, s.dl.URL()
// как резерв (для разработки, когда качалку явно не указали).
//
// С 19.09.2026 (Alex TG 20073: «качалка пусть запускается вместе с приложением»): если программа сама
// держит качалку (s.dl — есть папка с .venv, её путь в SOUNDFLOW_DOWNLOADER лаунчера), адрес отдаём,
// только когда она ответила на /health, иначе честное «ещё запускается». Порт при этом — из
// SOUNDFLOW_SIDECAR_URL (8001), чтобы остальные места, что ждут качалку там же, её находили.
// Нет s.dl — как раньше: адрес из SOUNDFLOW_SIDECAR_URL (качалка запущена отдельно).
func (s *Service) sidecarURL() string {
	if s.dl != nil {
		return s.dl.URL()
	}
	return os.Getenv("SOUNDFLOW_SIDECAR_URL")
}

// С 20.09.2026 (Alex TG 20122: «2») лайки сами по токену больше не подтягиваются: раздел «Твои лайки из
// Яндекс.Музыки» и GET /api/yandex/likes убраны, вместо них — плейлист по ссылке, см. yandex_playlist.go.

// hYandexDislikesImport — POST /api/yandex/dislikes/import: дизлайки личного
// аккаунта → чёрный список (legacy_marks blocked), молча, без вопросов —
// это не более разрушительно, чем уже существующий перенос старого чёрного
// списка (этап 10), просто новый источник.
func (s *Service) hYandexDislikesImport(w http.ResponseWriter, r *http.Request) {
	url := s.sidecarURL()
	if url == "" {
		http.Error(w, "качалка ещё запускается — попробуй через минуту", 503)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	items, err := sidecar.New(url).YandexDislikes(ctx)
	if err != nil {
		http.Error(w, err.Error(), 502)
		return
	}
	marks := make([]localdb.BlockedMark, 0, len(items))
	for _, it := range items {
		if it.Artist == "" && it.Title == "" {
			continue
		}
		marks = append(marks, localdb.BlockedMark{
			NormalizedKey: quality.NormalizedKey(it.Artist, it.Title),
			Artist:        it.Artist, Title: it.Title,
		})
	}
	n, err := s.db.ImportBlocked(marks)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	writeJSON(w, map[string]int{"imported": n})
}
