from __future__ import annotations
import asyncio
import logging
from typing import Any

import httpx
import yt_dlp  # type: ignore[import-untyped]

from ..main import SearchItem
from .filters import is_single_song

log = logging.getLogger(__name__)

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 SoundFlow/2"
SEARCH_URL = "https://rutube.ru/api/search/video/"

YDL_OPTS = {
    "quiet": True,
    "no_warnings": True,
    "skip_download": True,
    "ignoreerrors": True,
}


def _resolve_sync(video_url: str) -> str | None:
    try:
        with yt_dlp.YoutubeDL(YDL_OPTS) as ydl:
            info: dict[str, Any] = ydl.extract_info(video_url, download=False)
        return info.get("url")
    except Exception as exc:
        log.warning("rutube resolve failed for %s: %s", video_url, exc)
        return None


async def search_rutube(query: str, limit: int = 10) -> list[SearchItem]:
    try:
        async with httpx.AsyncClient(timeout=10.0, headers={"User-Agent": UA}) as client:
            res = await client.get(
                SEARCH_URL,
                params={"query": query, "page_size": limit},
            )
            if res.status_code != 200:
                log.warning("rutube REST status=%d", res.status_code)
                return []
            data = res.json()
    except Exception as exc:
        log.warning("rutube REST failed: %s", exc)
        return []

    results = data.get("results") or []
    items: list[SearchItem] = []
    for entry in results[:limit]:
        track_id = str(entry.get("id") or "")
        if not track_id:
            continue
        # Rutube REST не отдаёт is_live/live_status, фильтруем по title и duration
        if not is_single_song(
            title=entry.get("title"),
            duration=entry.get("duration"),
            is_live=bool(entry.get("is_livestream")),
        ):
            continue
        video_url = f"https://rutube.ru/video/{track_id}/"
        stream_url = await asyncio.to_thread(_resolve_sync, video_url)
        if not stream_url:
            continue
        author = entry.get("author") or {}
        items.append(
            SearchItem(
                provider="rutube",
                provider_track_id=track_id,
                provider_url=video_url,
                artist=str(author.get("name") or "Unknown Artist"),
                title=str(entry.get("title") or "Untitled"),
                duration_sec=int(entry["duration"]) if entry.get("duration") else None,
                cover_url=entry.get("thumbnail_url"),
                stream_url=stream_url,
            )
        )
    return items
