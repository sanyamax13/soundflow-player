package main

import (
	"context"
	"errors"

	"soundflow/server/internal/inference"
	"soundflow/server/internal/pathmap"
	"soundflow/server/internal/sidecar"
)

// localFinder — acquire.Finder для нового сервера. Скачивание (FindAudio),
// теги (ID3Info) и обложки Яндекса (YandexTrackCover) по-прежнему через
// Python-сайдкар (тонкий, без torch). А «звуковой отпечаток» — локально,
// движком ONNX в этом же процессе, без похода в питон.
type localFinder struct {
	*sidecar.Client // FindAudio, ID3Info, YandexTrackCover, YandexSearchArtist, Health
	eng             *inference.Engine
	pm              pathmap.Mapper
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
