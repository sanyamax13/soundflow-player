"""Режим 1 «Найти трек» — авто-цепочка для ОДНОГО трака.

Порядок (Alex 28.09.2026, было «Яндекс первым» с 08.09): musify → mp3party → Яндекс.
Смысл плеера — бесплатно, без подписок: сначала бесплатные источники, Яндекс — последним
запасным и только если человек вошёл (есть токен). Эталон длины по-прежнему берётся из
открытого поиска Яндекса — он без входа и без подписки.

Торренты сюда НЕ входят — это отдельный ручной режим «Торренты — обзор»
(torrent_browse.py): там Alex сам смотрит список релизов и выбирает.
"""
from __future__ import annotations

import asyncio
import logging
import os
import re
from dataclasses import dataclass, field
from typing import Any

from ..config import config
from ._validators import duration_off
from ..parsers.yandex_chart import yandex_track_duration
from . import musify_download as mus
from . import mp3party_download as m3p
from . import yandex as ym

log = logging.getLogger(__name__)


@dataclass
class AudioChainResult:
    file_path: str
    bitrate_kbps: int | None
    duration_sec: int | None
    size_bytes: int
    source: str
    provider_user: str
    provider_url: str
    extra_tracks: list[dict[str, Any]] = field(default_factory=list)


async def _safe(coro: Any, name: str) -> Any:
    """Сбой одного источника = «ничего не дал», цепочка идёт дальше."""
    try:
        return await coro
    except asyncio.CancelledError:
        raise
    except Exception as exc:  # noqa: BLE001
        log.warning("audio_chain: провайдер %s упал (%s), пропускаю", name, exc)
        return None


async def find_audio_chain(
    artist: str,
    title: str,
    *,
    skip_providers: set[str] | None = None,
    rejected_source_urls: set[str] | None = None,
    expected_duration_sec: int | None = None,
) -> AudioChainResult | None:
    skip = skip_providers or set()
    rejected = rejected_source_urls or set()

    # Эталон длины из Яндекса — чтобы из любого источника бралась именно та
    # версия (ремикс/обрезка/чужая запись под тем же именем отбрасывалась).
    if expected_duration_sec is None:
        expected_duration_sec = await _safe(
            asyncio.to_thread(yandex_track_duration, artist, title), "yandex-duration")
        if expected_duration_sec:
            log.info("audio_chain: %s — %s эталон длины %ss (Яндекс)",
                     artist, title, expected_duration_sec)

    # Правило (Alex 08.09.2026): не отдавать обрезок. Годен, если:
    #  - длина в допуске от эталона Яндекса (если эталон есть), И
    #  - не короче 40 с (кроме интро/аутро/скитов — там короткое законно).
    _short_ok = re.search(
        r"\b(intro|outro|interlude|skit|prelude|reprise|coda|overture|snippet)\b",
        f"{title}", re.I) is not None

    def _acceptable(dur: int | None) -> bool:
        if expected_duration_sec and duration_off(dur, expected_duration_sec):
            return False
        if dur and dur < 40 and not _short_ok:
            return False
        return True

    # 1. musify.club — бесплатный, обычно 320 mp3.
    if "musify" not in skip:
        mr = await _safe(mus.find_and_download(
            artist, title, rejected_source_urls=rejected,
            expected_duration_sec=expected_duration_sec), "musify")
        if mr is not None:
            if not _acceptable(mr.duration_sec):
                log.info("audio_chain: musify отдал обрезок (%ss vs %ss), пропускаю",
                         mr.duration_sec, expected_duration_sec)
            else:
                log.info("audio_chain: %s — musify успех (%skbps)", artist, mr.bitrate_kbps)
                return AudioChainResult(
                    file_path=mr.file_path,
                    bitrate_kbps=mr.bitrate_kbps,
                    duration_sec=mr.duration_sec,
                    size_bytes=mr.size_bytes,
                    source="musify",
                    provider_user="musify",
                    provider_url=mr.source_url,
                )

    # 2. mp3party.net. В РФ бывает отдаёт заглушки — не падаем.
    if "mp3party" not in skip:
        pr = await _safe(m3p.find_and_download(artist, title), "mp3party")
        if pr is not None:
            if not _acceptable(pr.duration_sec):
                log.info("audio_chain: mp3party wrong duration (%ss vs %ss), пропускаю",
                         pr.duration_sec, expected_duration_sec)
            elif pr.track_url in rejected:
                log.info("audio_chain: mp3party rejected by user: %s", pr.track_url)
            else:
                log.info("audio_chain: %s — mp3party успех (%skbps)", artist, pr.bitrate_kbps)
                return AudioChainResult(
                    file_path=pr.file_path,
                    bitrate_kbps=pr.bitrate_kbps,
                    duration_sec=pr.duration_sec,
                    size_bytes=pr.size_bytes,
                    source="mp3party",
                    provider_user="mp3party",
                    provider_url=pr.track_url,
                )

    # 3. Yandex Music — последний запасной: только если человек вошёл (нет токена → None).
    if "yandex" not in skip:
        ym_res = await _safe(ym.download_track(
            artist, title, config.track_cache_dir,
            expected_duration_sec=expected_duration_sec), "yandex")
        if ym_res is not None:
            ym_path, m = ym_res
            if not _acceptable(m.duration_sec):
                log.info("audio_chain: Yandex отдал обрезок (%ss vs %ss), пропускаю",
                         m.duration_sec, expected_duration_sec)
                try: os.remove(ym_path)
                except OSError: pass
            else:
                log.info("audio_chain: %s — Yandex успех (%skbps)", artist, m.bitrate_kbps)
                return AudioChainResult(
                    file_path=ym_path,
                    bitrate_kbps=m.bitrate_kbps,
                    duration_sec=m.duration_sec,
                    size_bytes=os.path.getsize(ym_path),
                    source="yandex",
                    provider_user="yandex",
                    provider_url=f"yandexmusic://{m.track_id}",
                )

    log.info("audio_chain: %s — %s не найден ни одним источником", artist, title)
    return None
