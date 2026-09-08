from __future__ import annotations
from unittest.mock import patch
import pytest
from fastapi.testclient import TestClient

from src.main import app, _parse_expire


client = TestClient(app)


def test_parse_expire_youtube():
    url = "https://rr5.googlevideo.com/videoplayback?expire=1777500000&ip=1.2.3.4&sig=abc"
    assert _parse_expire(url) == 1777500000


def test_parse_expire_missing():
    assert _parse_expire("https://example.com/audio.mp3") is None


def test_parse_expire_garbage():
    assert _parse_expire("not even a url") is None
    assert _parse_expire("https://x.com/?expire=abc") is None


def test_parse_expire_path_segment_youtube_live():
    url = "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/1777488941/ei/abc/playlist/index.m3u8"
    assert _parse_expire(url) == 1777488941


def test_resolve_youtube_returns_stream_url_and_expires_at():
    fake_info = {
        "url": "https://googlevideo.com/...?expire=1777500000&sig=zzz",
    }
    with patch("yt_dlp.YoutubeDL") as YDL:
        YDL.return_value.__enter__.return_value.extract_info.return_value = fake_info
        res = client.post(
            "/resolve",
            json={
                "provider": "youtube",
                "provider_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            },
        )
    assert res.status_code == 200
    body = res.json()
    assert body["stream_url"].startswith("https://googlevideo.com/")
    assert body["expires_at"] == 1777500000


def test_resolve_yt_dlp_failure_returns_502():
    with patch("yt_dlp.YoutubeDL") as YDL:
        YDL.return_value.__enter__.return_value.extract_info.side_effect = Exception(
            "extractor broken"
        )
        res = client.post(
            "/resolve",
            json={
                "provider": "youtube",
                "provider_url": "https://www.youtube.com/watch?v=broken",
            },
        )
    assert res.status_code == 502


def test_resolve_unknown_provider_returns_422():
    res = client.post(
        "/resolve",
        json={"provider": "soulseek", "provider_url": "x:y"},
    )
    assert res.status_code == 422
