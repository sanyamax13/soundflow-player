from __future__ import annotations
import asyncio
import logging
from typing import Any

import yt_dlp  # type: ignore[import-untyped]

from ..config import config
from ..main import SearchItem
from .filters import is_single_song

log = logging.getLogger(__name__)

YDL_OPTS: dict[str, Any] = {
    "quiet": True,
    "no_warnings": True,
    "extract_flat": False,
    "skip_download": True,
    "format": "bestaudio/best",
    # Один битый видеоролик в ytsearch5 не должен валить весь fallback.
    "ignoreerrors": True,
    # Без таймаутов yt-dlp висит когда YouTube отдаёт slow/medium responses
    # из-за bot-check. Получим что успели за разумное время.
    "socket_timeout": 12,
    "retries": 1,
    "extractor_retries": 0,
    "extractor_args": {
        "youtubepot-bgutilhttp": {
            "base_url": [config.bgutil_url],
        },
    },
}

# YouTube с 2026 года всё чаще требует «Sign in to confirm you're not a bot».
# Подсовываем cookies из локального браузера (чаще всего Chrome у Алексея на ПК).
# Если cookies взять не удалось — yt-dlp молча продолжит без них.
if config.yt_cookies_browser:
    YDL_OPTS["cookiesfrombrowser"] = (config.yt_cookies_browser,)


def _try_extract(opts: dict[str, Any], search_url: str) -> dict[str, Any] | None:
    with yt_dlp.YoutubeDL(opts) as ydl:
        return ydl.extract_info(search_url, download=False)


def _extract_sync(query: str, limit: int) -> list[SearchItem]:
    search_url = f"ytsearch{limit}:{query}"
    info: dict[str, Any] | None = None
    try:
        info = _try_extract(YDL_OPTS, search_url)
    except Exception as exc:
        msg = str(exc)
        # Chrome держит lock на cookie-БД (yt-dlp issue #7271). Fallback —
        # пробуем без cookies; результаты будут хуже из-за bot-check, но
        # лучше чем 0. Текст ошибки разный в разных версиях yt-dlp:
        # «could not copy», «cookie database», «failed to load cookies».
        if "cookie" in msg.lower():
            log.warning("youtube cookies unavailable, retrying without cookies")
            opts_no_cookies = {k: v for k, v in YDL_OPTS.items() if k != "cookiesfrombrowser"}
            try:
                info = _try_extract(opts_no_cookies, search_url)
            except Exception as exc2:
                log.warning("youtube fallback failed: %s", exc2)
                return []
        else:
            log.warning("youtube search failed: %s", exc)
            return []

    if not info or not isinstance(info.get("entries"), list):
        return []

    items: list[SearchItem] = []
    for entry in info["entries"]:
        if not entry:
            continue
        track_id = str(entry.get("id") or "")
        if not track_id:
            continue
        if not is_single_song(
            title=entry.get("title"),
            duration=entry.get("duration"),
            is_live=bool(entry.get("is_live")),
            live_status=entry.get("live_status"),
            categories=entry.get("categories"),
        ):
            continue
        webpage_url = str(
            entry.get("webpage_url") or f"https://www.youtube.com/watch?v={track_id}"
        )
        items.append(
            SearchItem(
                provider="youtube",
                provider_track_id=track_id,
                provider_url=webpage_url,
                artist=str(entry.get("uploader") or "Unknown Artist"),
                title=str(entry.get("title") or "Unknown Title"),
                duration_sec=int(entry["duration"]) if entry.get("duration") else None,
                cover_url=entry.get("thumbnail"),
                stream_url=entry.get("url"),
            )
        )
    return items


async def search_youtube(query: str, limit: int = 10) -> list[SearchItem]:
    return await asyncio.to_thread(_extract_sync, query, limit)
