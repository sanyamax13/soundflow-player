from __future__ import annotations
from unittest.mock import patch, MagicMock
import pytest

from src.providers.soulseek import search_soulseek


@pytest.mark.asyncio
async def test_search_collects_results_after_polling():
    fake_client = MagicMock()
    fake_client.searches.search_text.return_value = {"id": "search-1"}
    fake_client.searches.state.side_effect = [
        {"id": "search-1", "isComplete": False, "fileCount": 0},
        {"id": "search-1", "isComplete": True, "fileCount": 2},
    ]
    fake_client.searches.search_responses.return_value = [
        {
            "username": "user1",
            "files": [
                {
                    "filename": "Splean - Liniya zhizni.mp3",
                    "size": 5_500_000,
                    "bitRate": 320,
                }
            ],
        }
    ]

    with patch("src.providers.soulseek.SlskdClient", return_value=fake_client):
        items = await search_soulseek("splean", limit=5)

    assert len(items) == 1
    assert items[0].provider == "soulseek"
    assert items[0].title == "Splean - Liniya zhizni"
    assert items[0].stream_url is None
    assert items[0].provider_track_id.startswith("user1:")


@pytest.mark.asyncio
async def test_search_empty_when_no_responses():
    fake_client = MagicMock()
    fake_client.searches.search_text.return_value = {"id": "s2"}
    fake_client.searches.state.return_value = {
        "id": "s2",
        "isComplete": True,
        "fileCount": 0,
    }
    fake_client.searches.search_responses.return_value = []
    with patch("src.providers.soulseek.SlskdClient", return_value=fake_client):
        items = await search_soulseek("nothing", limit=5)
    assert items == []


@pytest.mark.asyncio
async def test_search_handles_slskd_error():
    fake_client = MagicMock()
    fake_client.searches.search_text.side_effect = Exception("slskd down")
    with patch("src.providers.soulseek.SlskdClient", return_value=fake_client):
        items = await search_soulseek("query", limit=5)
    assert items == []


@pytest.mark.asyncio
async def test_search_filters_non_audio():
    fake_client = MagicMock()
    fake_client.searches.search_text.return_value = {"id": "s3"}
    fake_client.searches.state.return_value = {
        "id": "s3",
        "isComplete": True,
        "fileCount": 2,
    }
    fake_client.searches.search_responses.return_value = [
        {
            "username": "u",
            "files": [
                {"filename": "song.mp3", "size": 5_000_000},
                {"filename": "cover.jpg", "size": 500_000},
                {"filename": "video.mkv", "size": 100_000_000},
            ],
        }
    ]
    with patch("src.providers.soulseek.SlskdClient", return_value=fake_client):
        items = await search_soulseek("query", limit=5)
    assert len(items) == 1
    assert items[0].title == "song"
