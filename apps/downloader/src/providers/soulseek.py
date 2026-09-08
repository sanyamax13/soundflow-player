from __future__ import annotations
import asyncio
import logging
import os
import re
import time
from typing import Any

from slskd_api import SlskdClient  # type: ignore[import-untyped]

from ..config import config
from ..main import SearchItem

log = logging.getLogger(__name__)

POLL_INTERVAL_SEC = 1.0
# Soulseek P2P медленный — peers отвечают неравномерно. Не ждём isComplete,
# а просто собираем что успело прийти за 15 секунд.
POLL_TIMEOUT_SEC = 15.0
MIN_RESULTS_BEFORE_BREAK = 5
AUDIO_EXTENSIONS = (".mp3", ".flac", ".ogg", ".m4a", ".wav")


def _track_id(username: str, filename: str) -> str:
    return f"{username}:{filename}"


def _strip_ext(filename: str) -> str:
    base = os.path.basename(filename)
    return re.sub(r"\.[^.]+$", "", base)


def _is_audio(filename: str) -> bool:
    return filename.lower().endswith(AUDIO_EXTENSIONS)


def _do_search_sync(query: str, limit: int) -> list[SearchItem]:
    try:
        client = SlskdClient(host=config.slskd_url, api_key=config.slskd_api_key)
        started = client.searches.search_text(query)
        search_id = started["id"]
    except Exception as exc:
        log.warning("soulseek init failed: %s", exc)
        return []

    elapsed = 0.0
    final_state: dict[str, Any] | None = None
    while elapsed < POLL_TIMEOUT_SEC:
        try:
            state = client.searches.state(search_id)
        except Exception as exc:
            log.warning("soulseek poll failed: %s", exc)
            break
        final_state = state
        if state.get("isComplete"):
            break
        # Если уже накопилось достаточно — выходим раньше, не ждём isComplete
        file_count = state.get("fileCount") or 0
        if file_count >= MIN_RESULTS_BEFORE_BREAK and elapsed >= 5.0:
            break
        time.sleep(POLL_INTERVAL_SEC)
        elapsed += POLL_INTERVAL_SEC

    if not final_state:
        return []

    # state не содержит responses — нужен отдельный endpoint
    try:
        responses = client.searches.search_responses(search_id)
    except Exception as exc:
        log.warning("soulseek fetch responses failed: %s", exc)
        return []

    items: list[SearchItem] = []
    for resp in responses or []:
        username = str(resp.get("username") or "")
        for f in resp.get("files") or []:
            fname = str(f.get("filename") or "")
            if not _is_audio(fname):
                continue
            items.append(
                SearchItem(
                    provider="soulseek",
                    provider_track_id=_track_id(username, fname),
                    # У Soulseek-треков нет публичного URL — резолв идёт через
                    # slskd download (Stage 5b+). Сюда кладём track_id чтобы
                    # позже параметризовать запрос на скачивание.
                    provider_url=_track_id(username, fname),
                    artist=username,
                    title=_strip_ext(fname),
                    duration_sec=None,
                    cover_url=None,
                    stream_url=None,
                )
            )
            if len(items) >= limit:
                return items
    return items


async def search_soulseek(query: str, limit: int = 5) -> list[SearchItem]:
    return await asyncio.to_thread(_do_search_sync, query, limit)
