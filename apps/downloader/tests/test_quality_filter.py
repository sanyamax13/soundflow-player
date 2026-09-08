"""Тесты version-фильтра (_validators): acquisition vs alternate-version.

Решение Алекса 16.06.2026: download/search/album пускает каверы/ремиксы, режет
только live/concert + откровенный мусор. is_alternate_version (union) не даёт
подсунуть ремикс/кавер/live вместо запрошенного оригинала, но разрешает их,
если пользователь сам искал такую версию.

Импортирует только stdlib-функции (_validators верхним уровнем тянет re/pathlib;
mutagen — лениво внутри других функций), поэтому тест идёт без аудио-зависимостей.
"""
from __future__ import annotations
import pytest

from src.providers._validators import (
    is_quality_title,
    is_alternate_version,
    _live_marker_hit,
)


def _acquire_ok(title: str) -> bool:
    return is_quality_title(title)[0]


@pytest.mark.parametrize(
    "title",
    [
        "Song (Live)",
        "Song [Live]",
        "Song - Live at Wembley",
        "Song - Live in Moscow",
        "Song (Live Performance)",
        "Song (Live Session)",
        "Концертная версия",
        "Песня (Концертная версия)",
        "Запись с концерта",
    ],
)
def test_reject_live_concert(title):
    assert not _acquire_ok(title), title


@pytest.mark.parametrize(
    "title",
    [
        "Song (Karaoke)",
        "Песня (Караоке)",
        "Song (Nightcore)",
        "Song (Slowed)",
        "Song (Slowed + Reverb)",
        "Song (Sped Up)",
        "Song (Instrumental)",
        "Песня (Инструментал)",
        "Песня (Минусовка)",
        "Song (Demo)",
        "Song (Bootleg)",
    ],
)
def test_reject_junk(title):
    assert not _acquire_ok(title), title


@pytest.mark.parametrize(
    "title",
    [
        "Song (Remix)",
        "Song (Cover)",
        "Песня (Ремикс)",
        "Песня (Кавер)",
        "Song (Extended Mix)",
        "Song (Club Mix)",
        "Song (Radio Edit)",
        "Song (Acoustic Version)",
        "Song (Acoustic)",
    ],
)
def test_allow_cover_remix_for_download(title):
    assert _acquire_ok(title), title


@pytest.mark.parametrize(
    "title",
    ["Live Is Life", "Live and Let Die", "Alive", "Delivery", "Concert Hall Dreams"],
)
def test_no_false_positive_live(title):
    # "live"/"concert" как часть имени песни — НЕ режем.
    assert _acquire_ok(title), title


def test_live_marker_hit_direct():
    assert _live_marker_hit("Song (Live)")
    assert _live_marker_hit("Song - Live at Wembley")
    assert _live_marker_hit("Концертная версия")
    assert not _live_marker_hit("Live Is Life")
    assert not _live_marker_hit("Song (Remix)")


def test_alternate_skips_unwanted_version_for_original_search():
    # Ищем оригинал — ремикс/кавер/live НЕ подсовываем.
    assert is_alternate_version("Song (Remix)", "Song")[0]
    assert is_alternate_version("Song (Cover)", "Song")[0]
    assert is_alternate_version("Song (Live)", "Song")[0]


def test_alternate_allows_when_user_wants_it():
    # Пользователь сам искал ремикс/кавер — разрешаем скачать.
    assert not is_alternate_version("Song (Remix)", "Song Remix")[0]
    assert not is_alternate_version("Song (Cover)", "Song Cover")[0]
    # Студийный матч с обычным запросом — не альтернатива.
    assert not is_alternate_version("Song", "Song")[0]


def test_alternate_no_false_positive_live_is_life():
    assert not is_alternate_version("Live Is Life", "Live Is Life")[0]
