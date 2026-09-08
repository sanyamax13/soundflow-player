"""musify.club fast-task provider — поиск + download + result для audio_chain.

Аналогично youtube_music_download / soundcloud_download:
- find_and_download(artist, title) → MusifyResult | None
- MusifyResult имеет .file_path, .bitrate_kbps, .duration_sec, .size_bytes, .source_url
"""
from __future__ import annotations
import logging
import re
from dataclasses import dataclass
from pathlib import Path

from ..config import config
from . import musify as mu

log = logging.getLogger(__name__)


@dataclass
class MusifyResult:
    file_path: str
    bitrate_kbps: int | None
    duration_sec: int | None
    size_bytes: int
    source_url: str
    artist: str
    title: str


async def find_and_download(
    artist: str,
    title: str,
    *,
    rejected_source_urls: set[str] | None = None,
    expected_duration_sec: int | None = None,
) -> MusifyResult | None:
    rejected = rejected_source_urls or set()

    match = await mu.find_track(artist, title, expected_duration_sec)
    if match is None:
        return None
    if match.track_url in rejected:
        log.info("musify: rejected by user: %s", match.track_url)
        return None

    # Скачиваем уже найденный match (без повторного поиска — musify limit'ит
    # частые запросы, а find_track выше уже отработал).
    result = await mu.download_match(match, config.track_cache_dir)
    if result is None:
        return None
    file_path, downloaded_match = result
    p = Path(file_path)
    if not p.exists():
        return None
    size = p.stat().st_size
    if size < 200_000:
        # Слишком мал — скорее всего залогинились на login страницу
        try:
            p.unlink()
        except OSError:
            pass
        return None

    return MusifyResult(
        file_path=file_path,
        bitrate_kbps=downloaded_match.bitrate_kbps,
        duration_sec=downloaded_match.duration_sec,
        size_bytes=size,
        source_url=downloaded_match.track_url,
        artist=downloaded_match.artist,
        title=downloaded_match.title,
    )
