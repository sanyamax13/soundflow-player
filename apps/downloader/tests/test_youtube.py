from __future__ import annotations
from unittest.mock import patch
import pytest

from src.providers.youtube import search_youtube


@pytest.mark.asyncio
async def test_search_returns_items_with_youtube_metadata():
    fake_info = {
        "entries": [
            {
                "id": "dQw4w9WgXcQ",
                "uploader": "Rick Astley",
                "title": "Never Gonna Give You Up",
                "duration": 213,
                "thumbnail": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
                "url": "https://rr5---sn-...mp4",
                "webpage_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                "categories": ["Music"],
            },
        ]
    }
    with patch("yt_dlp.YoutubeDL") as YDL:
        YDL.return_value.__enter__.return_value.extract_info.return_value = fake_info
        items = await search_youtube("never gonna give you up", limit=1)

    assert len(items) == 1
    assert items[0].provider == "youtube"
    assert items[0].provider_track_id == "dQw4w9WgXcQ"
    assert items[0].provider_url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    assert items[0].artist == "Rick Astley"


@pytest.mark.asyncio
async def test_search_handles_error_gracefully():
    with patch("yt_dlp.YoutubeDL") as YDL:
        YDL.return_value.__enter__.return_value.extract_info.side_effect = Exception("SABR")
        items = await search_youtube("query", limit=10)
    assert items == []
