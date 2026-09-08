from __future__ import annotations
import pytest

from src.providers.filters import is_single_song


def _normal(**overrides):
    base = {
        "title": "Sample Song",
        "duration": 200,
        "is_live": False,
        "live_status": "not_live",
    }
    base.update(overrides)
    return base


def test_normal_song_passes():
    assert is_single_song(**_normal())


def test_pass_short_track_30s():
    assert is_single_song(**_normal(duration=30))


def test_pass_long_jam_24min():
    assert is_single_song(**_normal(duration=24 * 60))


def test_drop_too_short():
    assert not is_single_song(**_normal(duration=15))


def test_drop_too_long():
    assert not is_single_song(**_normal(duration=26 * 60))


def test_drop_when_is_live_true():
    assert not is_single_song(**_normal(is_live=True))


@pytest.mark.parametrize("status", ["is_live", "was_live", "is_upcoming"])
def test_drop_live_statuses(status):
    assert not is_single_song(**_normal(live_status=status))


def test_pass_when_live_status_not_live_or_none():
    assert is_single_song(**_normal(live_status=None))
    assert is_single_song(**_normal(live_status="not_live"))


@pytest.mark.parametrize(
    "title",
    [
        "Best of Pink Floyd 2024",
        "Top 50 Hits 2024",
        "1 Hour of Lo-fi Beats",
        "10 hours relaxing music",
        "DJ Set live at Tomorrowland",
        "Megamix 90s",
        "The Joe Rogan Podcast Episode 2000",
        "Album Reaction Video",
        "Music Theory Tutorial",
        "Beatles Compilation",
        # Расширения для реальных кейсов с /search
        "Depeche Mode - Never Let Me Down Again (best live version)",
        "Depeche Mode Live At Wembley 2010",
        "Beatles - Live Performance 1965",
        "Pink Floyd - Live Recording London",
        "Andrea Parker DJ-Kicks",
        "Andrea Parker DJ Kicks 01",
        "DJ Fabio Reder - Programa EDM Show 377",
        "EDM Show 142",
        "Episode 47 - Pop Music",
        "Concert in Berlin",
        "Glastonbury 2023 Performance",
        "Festival Coachella 2024",
        # RU
        "Лучшее за 2024",
        "Топ 10 хитов",
        "1 час релакс музыки",
        "10 часов медитации",
        "Сборник русского рока",
        "Подкаст про музыку",
        "Концерт Машины Времени",
        "Фестиваль Нашествие 2023",
        "Выпуск 17 — Русский рок",
        "Передача 5 - Музыкальный обзор",
        "Эпизод 12 подкаста",
    ],
)
def test_drop_stopword_titles(title):
    assert not is_single_song(**_normal(title=title))


@pytest.mark.parametrize(
    "title",
    [
        "Live Forever",
        "Live and Let Die",
        "Remix of Despacito",
        "Echoes",
        "Bohemian Rhapsody",
        "Across the Universe",
    ],
)
def test_pass_legit_titles_without_stopwords(title):
    assert is_single_song(**_normal(title=title))


def test_drop_remix_compilation_but_pass_remix():
    # 'remix' это валидно (это всё ещё одна песня).
    assert is_single_song(**_normal(title="Despacito (Remix)"))
    # Но 'compilation' — нет.
    assert not is_single_song(**_normal(title="Best Remix Compilation 2024"))


def test_unknown_duration_passes():
    # Когда длительность неизвестна (None) — не блокируем по длительности.
    # SoundCloud иногда не отдаёт duration в search-выдаче.
    assert is_single_song(**_normal(duration=None))


# Вариант C — YouTube category soft-boost

def test_youtube_long_music_category_passes():
    assert is_single_song(
        **_normal(duration=12 * 60),
        categories=["Music"],
    )


def test_youtube_long_non_music_category_dropped():
    assert not is_single_song(
        **_normal(duration=12 * 60),
        categories=["Entertainment"],
    )


def test_youtube_short_non_music_category_passes():
    # Короткое (<10 мин) — категория не имеет значения, проходит.
    assert is_single_song(
        **_normal(duration=5 * 60),
        categories=["Entertainment"],
    )


def test_categories_none_does_not_block():
    # Не-YouTube провайдеры не передают categories — фильтр не применяется.
    assert is_single_song(**_normal(duration=12 * 60), categories=None)


def test_youtube_categories_case_insensitive():
    assert is_single_song(
        **_normal(duration=12 * 60),
        categories=["MUSIC"],
    )
