"""Unit-тесты для cleanup helper'ов в audio_chain.

Проверяем что `_delete_losing_file`:
  - удаляет проигравшего fast-кандидата если он лежит в cache_dir;
  - не трогает winner_path (страховка от самоудаления);
  - не трогает пути вне cache (например в albums_dir / music / temp);
  - не падает если файла уже нет.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from src.providers.audio_chain import _delete_losing_file


@pytest.fixture
def fake_dirs(tmp_path: Path) -> tuple[Path, Path]:
    cache_dir = tmp_path / "cache"
    albums_dir = tmp_path / "music"
    cache_dir.mkdir()
    albums_dir.mkdir()
    return cache_dir, albums_dir


def test_deletes_loser_in_cache(fake_dirs: tuple[Path, Path]) -> None:
    cache_dir, albums_dir = fake_dirs
    loser = cache_dir / "loser.m4a"
    loser.write_bytes(b"fake-audio")

    deleted = _delete_losing_file(
        str(loser),
        str(cache_dir / "winner.mp3"),
        "lost_to_soulseek",
        cache_dir=cache_dir,
        albums_dir=albums_dir,
    )

    assert deleted is True
    assert not loser.exists()


def test_does_not_delete_winner(fake_dirs: tuple[Path, Path]) -> None:
    cache_dir, albums_dir = fake_dirs
    winner = cache_dir / "winner.mp3"
    winner.write_bytes(b"fake-audio")

    deleted = _delete_losing_file(
        str(winner),
        str(winner),
        "lost_to_soulseek",
        cache_dir=cache_dir,
        albums_dir=albums_dir,
    )

    assert deleted is False
    assert winner.exists()


def test_does_not_delete_outside_cache(
    tmp_path: Path,
    fake_dirs: tuple[Path, Path],
) -> None:
    cache_dir, albums_dir = fake_dirs
    outside = tmp_path / "outside.mp3"
    outside.write_bytes(b"fake-audio")

    deleted = _delete_losing_file(
        str(outside),
        None,
        "lost_to_rutor",
        cache_dir=cache_dir,
        albums_dir=albums_dir,
    )

    assert deleted is False
    assert outside.exists()


def test_does_not_delete_in_albums_dir(fake_dirs: tuple[Path, Path]) -> None:
    cache_dir, albums_dir = fake_dirs
    album_track = albums_dir / "Some Album" / "01 - Track.mp3"
    album_track.parent.mkdir(parents=True)
    album_track.write_bytes(b"fake-audio")

    deleted = _delete_losing_file(
        str(album_track),
        None,
        "lost_to_rutor",
        cache_dir=cache_dir,
        albums_dir=albums_dir,
    )

    assert deleted is False
    assert album_track.exists()


def test_missing_file_no_throw(fake_dirs: tuple[Path, Path]) -> None:
    cache_dir, albums_dir = fake_dirs
    missing = cache_dir / "never-was.mp3"

    deleted = _delete_losing_file(
        str(missing),
        None,
        "lost_to_rutor",
        cache_dir=cache_dir,
        albums_dir=albums_dir,
    )

    assert deleted is False


def test_empty_and_none_path(fake_dirs: tuple[Path, Path]) -> None:
    cache_dir, albums_dir = fake_dirs
    assert (
        _delete_losing_file(None, None, "test", cache_dir=cache_dir, albums_dir=albums_dir)
        is False
    )
    assert (
        _delete_losing_file("", None, "test", cache_dir=cache_dir, albums_dir=albums_dir) is False
    )


def test_winner_string_match_skips_delete(fake_dirs: tuple[Path, Path]) -> None:
    """Строковое сравнение candidate_path == winner_path должно отрабатывать
    как safety даже когда другие проверки пропустили бы."""
    cache_dir, albums_dir = fake_dirs
    winner = cache_dir / "track.mp3"
    winner.write_bytes(b"fake-audio")

    assert (
        _delete_losing_file(
            str(winner),
            str(winner),
            "test",
            cache_dir=cache_dir,
            albums_dir=albums_dir,
        )
        is False
    )
    assert winner.exists()
