"""Unit-тесты Stage 2 path translation (config.swap_root + Config.to_*).

Sidecar на fg физически пишет в LOCAL (D:\\SoundFlow\\*), но возвращает API
CANONICAL (E:\\soundflow-data\\*). На brain LOCAL == CANONICAL → полный no-op.

Тесты используют POSIX-подобные tmp-пути (на CI/Win одинаково через os.sep) —
проверяется только строковая логика префиксов, без обращения к ФС.
"""
from __future__ import annotations

import os
from pathlib import Path

import pytest

from src.config import Config, swap_root


def _cfg(
    local_cache: Path,
    canon_cache: Path,
    local_albums: Path,
    canon_albums: Path,
) -> Config:
    """Минимальная сборка frozen Config — только path-поля важны для translation,
    остальное заглушки."""
    return Config(
        sidecar_port=8001,
        sidecar_host="127.0.0.1",
        bgutil_url="",
        log_level="INFO",
        slskd_url="",
        slskd_api_key="",
        slskd_downloads_dir=Path("/tmp/slskd"),
        track_cache_dir=local_cache,
        yt_cookies_browser="",
        qbt_host="",
        qbt_port=8080,
        qbt_user="",
        qbt_pass="",
        albums_dir=local_albums,
        tapochek_user="",
        tapochek_pass="",
        canonical_cache_dir=canon_cache,
        canonical_albums_dir=canon_albums,
    )


# ---- swap_root: чистая функция ----

def test_swap_root_none() -> None:
    assert swap_root(None, Path("/a"), Path("/b")) is None


def test_swap_root_noop_when_equal() -> None:
    # brain: local == canonical → путь не меняется
    p = str(Path("/data/cache") / "Artist - Title.mp3")
    assert swap_root(p, Path("/data/cache"), Path("/data/cache")) == p


def test_swap_root_translates_inside() -> None:
    local = Path("/local/cache")
    canon = Path("/canon/cache")
    p = str(local / "Artist - Title.mp3")
    out = swap_root(p, local, canon)
    assert out == str(canon / "Artist - Title.mp3")


def test_swap_root_translates_nested() -> None:
    local = Path("/local/music")
    canon = Path("/canon/music")
    p = str(local / "Album" / "01 Track.mp3")
    out = swap_root(p, local, canon)
    assert out == str(canon / "Album" / "01 Track.mp3")


def test_swap_root_root_itself() -> None:
    out = swap_root(str(Path("/local/cache")), Path("/local/cache"), Path("/canon/cache"))
    assert out == str(Path("/canon/cache"))


def test_swap_root_passthrough_outside() -> None:
    # путь вне from_root возвращается без изменений
    p = str(Path("/somewhere/else/x.mp3"))
    assert swap_root(p, Path("/local/cache"), Path("/canon/cache")) == p


def test_swap_root_case_insensitive_prefix() -> None:
    # Windows fs регистронезависим: префикс с другим регистром всё равно матчится
    local = Path("E:/SoundFlow/Cache")
    canon = Path("E:/soundflow-data/cache")
    p = "e:/soundflow/cache/Track.mp3"
    out = swap_root(p, local, canon)
    assert os.path.normcase(out) == os.path.normcase(
        str(Path("E:/soundflow-data/cache/Track.mp3"))
    )


# ---- Config.to_canonical / to_local ----

def test_to_canonical_cache_and_albums() -> None:
    cfg = _cfg(
        local_cache=Path("/D/cache"),
        canon_cache=Path("/E/cache"),
        local_albums=Path("/D/music"),
        canon_albums=Path("/E/music"),
    )
    assert cfg.to_canonical(str(Path("/D/cache/T.mp3"))) == str(Path("/E/cache/T.mp3"))
    assert cfg.to_canonical(str(Path("/D/music/A/1.mp3"))) == str(Path("/E/music/A/1.mp3"))


def test_to_canonical_passthrough_and_none() -> None:
    cfg = _cfg(Path("/D/cache"), Path("/E/cache"), Path("/D/music"), Path("/E/music"))
    assert cfg.to_canonical(None) is None
    outside = str(Path("/tmp/other.mp3"))
    assert cfg.to_canonical(outside) == outside


def test_to_local_is_inverse() -> None:
    cfg = _cfg(Path("/D/cache"), Path("/E/cache"), Path("/D/music"), Path("/E/music"))
    assert cfg.to_local(str(Path("/E/cache/T.mp3"))) == str(Path("/D/cache/T.mp3"))
    assert cfg.to_local(str(Path("/E/music/A/1.mp3"))) == str(Path("/D/music/A/1.mp3"))
    assert cfg.to_local(None) is None


def test_brain_mode_is_full_noop() -> None:
    # canonical == local (env не задан) → обе стороны no-op
    cfg = _cfg(Path("/data/cache"), Path("/data/cache"), Path("/data/music"), Path("/data/music"))
    p_cache = str(Path("/data/cache/T.mp3"))
    p_music = str(Path("/data/music/A/1.mp3"))
    assert cfg.to_canonical(p_cache) == p_cache
    assert cfg.to_canonical(p_music) == p_music
    assert cfg.to_local(p_cache) == p_cache
    assert cfg.to_local(p_music) == p_music


# ---- B6: SIDECAR_HOST configurable ----

def test_sidecar_host_default_is_loopback(monkeypatch: pytest.MonkeyPatch) -> None:
    # brain / default: env не задан → 127.0.0.1 (поведение как было)
    monkeypatch.delenv("SIDECAR_HOST", raising=False)
    assert Config.from_env().sidecar_host == "127.0.0.1"


def test_sidecar_host_env_override(monkeypatch: pytest.MonkeyPatch) -> None:
    # fg Stage 2: SIDECAR_HOST=0.0.0.0 → слушать на всех интерфейсах
    monkeypatch.setenv("SIDECAR_HOST", "0.0.0.0")
    assert Config.from_env().sidecar_host == "0.0.0.0"
