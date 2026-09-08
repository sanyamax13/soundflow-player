from __future__ import annotations
from unittest.mock import patch
import pytest

from src.providers.soundcloud import search_soundcloud


@pytest.mark.asyncio
async def test_search_returns_items_from_yt_dlp_entries():
    fake_info = {
        "entries": [
            {
                "id": "12345",
                "uploader": "Artist1",
                "title": "Song1",
                "duration": 213,
                "thumbnail": "https://i1.sndcdn.com/cover1.jpg",
                "url": "https://api-v2.soundcloud.com/media/...mp3",
                "webpage_url": "https://soundcloud.com/artist1/song1",
            },
            {
                "id": "67890",
                "uploader": "Artist2",
                "title": "Song2",
                "duration": None,
                "thumbnail": None,
                "url": "https://api-v2.soundcloud.com/media/...mp3",
                "webpage_url": "https://soundcloud.com/artist2/song2",
            },
        ]
    }
    with patch("yt_dlp.YoutubeDL") as YDL:
        YDL.return_value.__enter__.return_value.extract_info.return_value = fake_info
        items = await search_soundcloud("test query", limit=2)

    assert len(items) == 2
    assert items[0].provider == "soundcloud"
    assert items[0].provider_track_id == "12345"
    assert items[0].provider_url == "https://soundcloud.com/artist1/song1"
    assert items[0].artist == "Artist1"
    assert items[0].title == "Song1"
    assert items[0].duration_sec == 213
    assert items[0].cover_url == "https://i1.sndcdn.com/cover1.jpg"
    assert items[0].stream_url is not None


@pytest.mark.asyncio
async def test_search_handles_yt_dlp_error_gracefully():
    with patch("yt_dlp.YoutubeDL") as YDL:
        YDL.return_value.__enter__.return_value.extract_info.side_effect = Exception(
            "network down"
        )
        items = await search_soundcloud("query", limit=10)
    assert items == []


@pytest.mark.asyncio
async def test_search_empty_when_no_entries():
    with patch("yt_dlp.YoutubeDL") as YDL:
        YDL.return_value.__enter__.return_value.extract_info.return_value = {"entries": []}
        items = await search_soundcloud("query", limit=10)
    assert items == []
