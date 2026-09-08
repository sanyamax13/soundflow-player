"""Анализ громкости трека через ffmpeg ebur128/loudnorm (rev. 11.05.2026).

Зачем нужен. Каждый трек записан и смастерен с разной воспринимаемой
громкостью. Beatles 1965 — тише на 10-15 dB чем Drake 2024. Без
нормализации плеер прыгает между треками. Spotify/Apple используют
выравнивание по LUFS (Loudness Units relative to Full Scale).

Что считаем:
- integrated_loudness (LUFS) — реальная воспринимаемая громкость трека
  по EBU R128 / ITU-R BS.1770 standard. Spotify target = -14 LUFS.
- true_peak (dBTP) — пиковое значение в dB True Peak. Нужно чтобы при
  boost тихих треков плеер не вышел в clipping (true_peak + gain > 0 dBTP
  → искажения). Limiter в плеере страхует, но и анализ полезен.

Что НЕ считаем:
- loudness_range (LRA) — динамический диапазон. Нужен для album-mode,
  пока без него (per-track normalization).

Реализация: subprocess ffmpeg, парсинг JSON из stderr. Один проход
~2-5 сек на mp3 длиной 3-4 минуты на CPU. Можем в backfill — пройти
по всем track_files за несколько часов.
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger(__name__)

FFMPEG_TIMEOUT_SEC = 30.0  # 4-минутный mp3 анализируется ~3-5 сек
# Регекс для поиска JSON-блока loudnorm в stderr ffmpeg.
# loudnorm выводит обычные strings и в конце JSON `{ ... }`.
_RE_JSON_BLOCK = re.compile(r"\{[^{}]*\"input_i\"[^{}]*\}", re.S)


@dataclass
class LoudnessResult:
    integrated_lufs: float
    true_peak_db: float


async def analyze_loudness(file_path: str) -> LoudnessResult | None:
    """Запускает ffmpeg ebur128 анализ. Возвращает (integrated LUFS, true_peak dBTP)
    или None если файл не найден / ffmpeg упал / JSON не распарсили.

    Безопасно работать в концurrency — каждый вызов = отдельный subprocess.
    """
    p = Path(file_path)
    if not p.exists():
        log.warning("loudness: файл не найден: %s", file_path)
        return None

    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostats",
        "-i", str(p),
        "-af", "loudnorm=print_format=json",
        "-f", "null",
        "-",
    ]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            _, stderr = await asyncio.wait_for(proc.communicate(), timeout=FFMPEG_TIMEOUT_SEC)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            log.warning("loudness: ffmpeg timeout %ds для %s", FFMPEG_TIMEOUT_SEC, file_path)
            return None
    except FileNotFoundError:
        log.error("loudness: ffmpeg не найден в PATH")
        return None
    except Exception as exc:
        log.warning("loudness: ffmpeg ошибка для %s: %s", file_path, exc)
        return None

    if proc.returncode != 0:
        log.warning(
            "loudness: ffmpeg exit %d для %s — stderr tail: %s",
            proc.returncode, file_path, stderr.decode("utf-8", errors="replace")[-300:],
        )
        return None

    text = stderr.decode("utf-8", errors="replace")
    match = _RE_JSON_BLOCK.search(text)
    if not match:
        log.warning("loudness: JSON блок не найден в stderr для %s", file_path)
        return None
    try:
        data = json.loads(match.group(0))
        lufs = float(data["input_i"])
        peak = float(data["input_tp"])
    except (json.JSONDecodeError, KeyError, ValueError) as exc:
        log.warning("loudness: не смог распарсить JSON %s: %s", file_path, exc)
        return None

    # Sanity check: LUFS обычно от -50 до 0, true_peak от -50 до +5
    if not (-70.0 <= lufs <= 0.0) or not (-70.0 <= peak <= 10.0):
        log.warning(
            "loudness: невероятные значения LUFS=%.2f peak=%.2f для %s",
            lufs, peak, file_path,
        )
        return None

    return LoudnessResult(integrated_lufs=lufs, true_peak_db=peak)
