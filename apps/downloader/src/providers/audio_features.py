"""Audio embedding extraction через PANNs CNN14.

Используется для алгоритма «Твой Вайб» (Stage 6) — для каждого mp3 в
track_files считаем 2048-D embedding из penultimate layer CNN14, сохраняем
в tracks.feature_vector. Похожие треки = cosine similarity между векторами.

PANNs (Pretrained Audio Neural Networks) натренированы на AudioSet (2M клипов
с YouTube). На CPU inference занимает ~1-2 сек на 3-минутный mp3 после
загрузки аудио (librosa). Модель Cnn14_mAP=0.431.pth (~300 МБ) хранится в
~/panns_data/, скачивается один раз при первом импорте.

Архитектурно — singleton: при первом обращении грузим модель, потом
переиспользуем. Чтобы не блокировать event loop FastAPI, inference крутится
в asyncio.to_thread.
"""
from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

_model: Any = None
_model_lock = asyncio.Lock()


def _load_model_sync() -> Any:
    """Блокирующая загрузка PANNs CNN14. ~2 сек на CPU."""
    global _model
    if _model is not None:
        return _model
    log.info("audio_features: загружаю PANNs CNN14...")
    from panns_inference import AudioTagging  # type: ignore[import-untyped]

    _model = AudioTagging(checkpoint_path=None, device="cpu")
    log.info("audio_features: модель загружена")
    return _model


def _analyze_sync(file_path: str) -> list[float] | None:
    """Считает 2048-D embedding для mp3. Блокирующий — звать в to_thread."""
    fp = Path(file_path)
    if not fp.exists():
        log.warning("audio_features: file not found %s", file_path)
        return None

    try:
        import librosa  # type: ignore[import-untyped]
        import numpy as np

        # PANNs ожидают 32 kHz mono. librosa.load умеет ресемплить.
        audio, _sr = librosa.load(str(fp), sr=32000, mono=True)
    except Exception as exc:
        log.warning("audio_features: librosa load failed for %s: %s", file_path, exc)
        return None

    model = _load_model_sync()
    try:
        _clipwise_output, embedding = model.inference(audio[None, :])
    except Exception as exc:
        log.warning("audio_features: PANNs inference failed for %s: %s", file_path, exc)
        return None

    # embedding shape: (1, 2048), float32
    vec = embedding[0].tolist()
    if not isinstance(vec, list) or len(vec) != 2048:
        log.error("audio_features: неожиданный shape embedding для %s", file_path)
        return None
    return vec


async def analyze_audio(file_path: str) -> list[float] | None:
    """Async wrapper — кладёт inference в thread pool, не блокирует event loop.

    Под глобальным lock — модель не thread-safe для одновременных inference,
    и второй call всё равно бы CPU-bound ждал освобождения. Серийность не
    проблема: 1-2 сек на трек, типичный prefetch это 100 mp3 = пара минут.
    """
    async with _model_lock:
        return await asyncio.to_thread(_analyze_sync, file_path)
