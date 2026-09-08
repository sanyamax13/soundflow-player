"""Тесты validate_quality_metadata — отлов ремиксов/club-mix/extended/etc.
по ID3 title и Soulseek-filename.

Дополняет validate_id3_match (тот проверяет что в файле наш артист+название;
этот — что в нём нет слов-маркеров плохой версии вроде "(Club Mix)").
"""
from __future__ import annotations

from pathlib import Path

from src.providers._validators import validate_quality_metadata


def _make_dummy_file(tmp_path: Path) -> Path:
    """Создаёт файл-болванку. ID3 не нужны — мокаем _extract_id3_title."""
    p = tmp_path / "test.mp3"
    p.write_bytes(b"x" * 1024)
    return p


def test_validate_quality_metadata_clean(tmp_path, monkeypatch):
    """Чистый ID3 title + чистый filename — пропускает, файл на месте."""
    p = _make_dummy_file(tmp_path)
    monkeypatch.setattr(
        "src.providers._validators._extract_id3_title",
        lambda _path: "Billie Jean",
    )
    ok = validate_quality_metadata(
        p, "Michael Jackson - Billie Jean.mp3", source="test",
    )
    assert ok is True
    assert p.exists()


def test_validate_quality_metadata_dirty_id3_title(tmp_path, monkeypatch):
    """ID3 title содержит 'Club Mix' — удаляет файл, False."""
    p = _make_dummy_file(tmp_path)
    monkeypatch.setattr(
        "src.providers._validators._extract_id3_title",
        lambda _path: "Billie Jean (Cash Cash Club Mix)",
    )
    ok = validate_quality_metadata(
        p, "Michael Jackson - Billie Jean.mp3", source="test",
    )
    assert ok is False
    assert not p.exists()


def test_validate_quality_metadata_dirty_filename(tmp_path, monkeypatch):
    """Filename содержит 'Remix' — удаляет файл, False (даже при чистом ID3)."""
    p = _make_dummy_file(tmp_path)
    monkeypatch.setattr(
        "src.providers._validators._extract_id3_title",
        lambda _path: "Billie Jean",
    )
    ok = validate_quality_metadata(
        p, "DJ Top - Billie Jean Remix 2024.mp3", source="test",
    )
    assert ok is False
    assert not p.exists()
