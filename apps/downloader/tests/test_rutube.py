from __future__ import annotations
from unittest.mock import patch, AsyncMock
import pytest

from src.providers.rutube import search_rutube


@pytest.mark.asyncio
async def test_search_returns_items_from_rutube_api():
    fake_search = {
        "results": [
            {
                "id": "abc123",
                "title": "Сплин — Линия жизни",
                "author": {"name": "Сплин"},
                "duration": 245,
                "thumbnail_url": "https://pic.rutubelist.ru/abc123.jpg",
            }
        ]
    }
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value.status_code = 200
        mock_get.return_value.json = lambda: fake_search

        with patch("yt_dlp.YoutubeDL") as YDL:
            YDL.return_value.__enter__.return_value.extract_info.return_value = {
                "url": "https://rutube.ru/cdn/abc123.mp4",
            }
            items = await search_rutube("сплин", limit=1)

    assert len(items) == 1
    assert items[0].provider == "rutube"
    assert items[0].provider_track_id == "abc123"
    assert items[0].provider_url == "https://rutube.ru/video/abc123/"
    assert items[0].artist == "Сплин"
    assert items[0].stream_url == "https://rutube.ru/cdn/abc123.mp4"


@pytest.mark.asyncio
async def test_search_handles_rest_error():
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value.status_code = 403
        items = await search_rutube("query", limit=10)
    assert items == []


@pytest.mark.asyncio
async def test_search_handles_resolve_failure_per_item():
    fake_search = {
        "results": [
            {"id": "ok", "title": "T1", "author": {"name": "A"}, "duration": 100, "thumbnail_url": ""},
            {"id": "fail", "title": "T2", "author": {"name": "B"}, "duration": 100, "thumbnail_url": ""},
        ]
    }
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value.status_code = 200
        mock_get.return_value.json = lambda: fake_search

        call_count = 0

        def extract_side_effect(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 2:
                raise Exception("resolve failed")
            return {"url": "https://rutube.ru/cdn/ok.mp4"}

        with patch("yt_dlp.YoutubeDL") as YDL:
            YDL.return_value.__enter__.return_value.extract_info.side_effect = extract_side_effect
            items = await search_rutube("test", limit=2)
    assert len(items) == 1
    assert items[0].provider_track_id == "ok"
