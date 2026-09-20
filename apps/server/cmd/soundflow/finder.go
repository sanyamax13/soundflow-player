package main

import (
	"context"
	"errors"
	"log"
	"time"

	"soundflow/server/internal/inference"
	"soundflow/server/internal/pathmap"
	"soundflow/server/internal/sidecar"
)

// torrentProviders — торрент-источники в цепочке сайдкара. Они тяжёлые (качают
// альбом целиком через qBittorrent), поэтому идут вторым заходом, только когда
// Яндекс песню не дал (Alex TG 20212/20214: «качает с Яндекса и торрентов»).
var torrentProviders = []string{"nnmclub", "rutor", "tapochek"}

// torrentStageTimeout — сколько ждём торрент-ступень: поиск по трекерам +
// скачивание альбома. Обычных 8 минут клиента на это может не хватить.
const torrentStageTimeout = 11 * time.Minute

// localFinder — acquire.Finder для нового сервера. Скачивание (FindAudio),
// теги (ID3Info) и обложки Яндекса (YandexTrackCover) по-прежнему через
// Python-сайдкар (тонкий, без torch). А «звуковой отпечаток» — локально,
// движком ONNX в этом же процессе, без похода в питон.
type localFinder struct {
	*sidecar.Client // FindAudio, ID3Info, YandexTrackCover, YandexSearchArtist, Health
	eng             *inference.Engine
	pm              pathmap.Mapper
	// startTorrents — включить qBittorrent перед торрент-ступенью. nil — обычный
	// ensureQBittorrent (подмена нужна только тестам).
	startTorrents func() error
}

// FindAudio — поиск и скачивание в два захода. Сначала только Яндекс (быстро,
// 320 кбит/с); не нашёл — программа сама включает qBittorrent и ищет по
// торрент-трекерам (nnmclub, rutor, tapochek). Так лёгкая песня не тянет за
// собой торренты, а редкая всё-таки находится. Что вызывающий сам велел
// пропустить (skip), пропускаем в обоих заходах.
func (f *localFinder) FindAudio(ctx context.Context, artist, title string, expectedDurationSec int, skip []string) (sidecar.FindAudioResult, error) {
	res, err := f.Client.FindAudio(ctx, artist, title, expectedDurationSec, withSkipped(skip, torrentProviders...))
	if err != nil || res.Found {
		return res, err
	}
	if len(torrentProviders) == countSkipped(skip, torrentProviders) {
		return res, nil // торренты вызывающий отключил сам
	}
	start := f.startTorrents
	if start == nil {
		start = ensureQBittorrent
	}
	if err := start(); err != nil {
		// Не нашли и торренты недоступны — для вызывающего это «не найдено»,
		// причину оставляем в журнале программы.
		log.Printf("торренты для «%s — %s»: %v", artist, title, err)
		return res, nil
	}
	return f.Client.WithTimeout(torrentStageTimeout).FindAudio(ctx, artist, title, expectedDurationSec, withSkipped(skip, "yandex"))
}

// withSkipped — skip плюс ещё источники (без повторов, исходный срез не трогаем).
func withSkipped(skip []string, more ...string) []string {
	out := append([]string(nil), skip...)
	for _, m := range more {
		if countSkipped(out, []string{m}) == 0 {
			out = append(out, m)
		}
	}
	return out
}

// countSkipped — сколько из names уже есть в skip.
func countSkipped(skip, names []string) int {
	n := 0
	for _, name := range names {
		for _, s := range skip {
			if s == name {
				n++
				break
			}
		}
	}
	return n
}

// AnalyzeFeatures считает 2048-мерный отпечаток трека по локальному файлу.
// canonicalPath — канонический (E:\soundflow-data\...); переводим в реальный
// путь на этой машине и гоняем через CNN14 (onnxruntime + ffmpeg).
func (f *localFinder) AnalyzeFeatures(ctx context.Context, canonicalPath string) ([]float32, error) {
	if f.eng == nil {
		return nil, errors.New("движок отпечатков не загружен (нет onnxruntime.dll / cnn14.onnx рядом с exe)")
	}
	return f.eng.EmbedFile(f.pm.ToLocal(canonicalPath))
}
