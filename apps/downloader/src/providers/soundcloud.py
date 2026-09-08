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
    "ignoreerrors": True,
}
if config.yt_cookies_browser:
    # Cookies из браузера — иногда помогают обойти SoundCloud rate-limit/SSL.
    YDL_OPTS["cookiesfrombrowser"] = (config.yt_cookies_browser,)


def _try_extract(opts: dict[str, Any], search_url: str) -> dict[str, Any] | None:
    with yt_dlp.YoutubeDL(opts) as ydl:
        return ydl.extract_info(search_url, download=False)


def _extract_sync(query: str, limit: int) -> list[SearchItem]:
    search_url = f"scsearch{limit}:{query}"
    info: dict[str, Any] | None = None
    try:
        info = _try_extract(YDL_OPTS, search_url)
    except Exception as exc:
        msg = str(exc)
        if "cookie" in msg.lower():
            log.warning("soundcloud cookies unavailable, retrying without cookies")
            opts_no_cookies = {k: v for k, v in YDL_OPTS.items() if k != "cookiesfrombrowser"}
            try:
                info = _try_extract(opts_no_cookies, search_url)
            except Exception as exc2:
                log.warning("soundcloud fallback failed: %s", exc2)
                return []
        else:
            log.warning("soundcloud search failed: %s", exc)
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
        ):
            continue
        # webpage_url — canonical URL страницы трека на soundcloud.com.
        # yt-dlp умеет по нему extract_info позже, чтобы заново получить stream URL.
        # Если webpage_url не пришёл — fallback на конструируемый по slug.
        webpage_url = str(entry.get("webpage_url") or entry.get("original_url") or "")
        if not webpage_url:
            continue
        items.append(
            SearchItem(
                provider="soundcloud",
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


async def search_soundcloud(query: str, limit: int = 10) -> list[SearchItem]:
    return await asyncio.to_thread(_extract_sync, query, limit)
