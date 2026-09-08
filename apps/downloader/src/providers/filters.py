"""Фильтр одиночных песен.

Цель: пропускать только треки вида «одна песня одного исполнителя».
Отсеиваем live-стримы, подкасты, сборники, миксы, обзоры, реакции,
туториалы, эпизоды подкастов, DJ-сеты, плейлисты, слишком короткие
заставки и многочасовые компиляции.

Каша из топора, baseline ~80% точности. Если будут осечки — расширяем
STOPWORDS_RE или подключаем второй слой (категория YouTube или LLM).
"""
from __future__ import annotations
import re

# Минимум 30с (короткие заставки/jingles), максимум 25мин (длинные джемы
# вроде Pink Floyd Echoes 23 мин ещё пускаем, всё что длиннее — почти
# наверняка концерт/микс/подкаст).
MIN_DURATION_SEC = 30
MAX_DURATION_SEC = 25 * 60

# Стоп-слова в названии. \b — границы слова, чтобы не ловить "remix" по
# подстроке "mix". Чувствительность к регистру отключена ниже.
_STOPWORD_PATTERNS = [
    r"\bmix(?:tape|es)?\b",
    r"\bcompilation\b",
    r"\bpodcast\b",
    r"\binterview\b",
    r"\btop\s*\d+\b",
    r"\bbest\s+of\b",
    r"\bbest\s+\w+\s+(?:live|concert)\b",
    r"\blive\s+(?:version|recording|performance|set|at|in|from)\b",
    r"\bconcert\b",
    r"\bfestival\b",
    r"\bglastonbury\b",
    r"\d+\s*(?:hour|hours|hr|hrs)\b",
    r"\bmegamix\b",
    r"\breview\b",
    r"\breaction\b",
    r"\btutorial\b",
    r"\bepisode\s*\d*\b",
    r"\bdj[- _]?set\b",
    r"\bdj[- _]?kicks\b",
    r"\bdj[- _]?mix\b",
    r"\bplaylist\b",
    r"\bshow\s*\d+\b",
    r"\bprograma\b",
    # RU-варианты для Rutube/SC RU
    r"\bмикс\b",
    r"\bсборник\b",
    r"\bподкаст\b",
    r"\bинтервью\b",
    r"\bтоп\s*\d+\b",
    r"\bлучшее\b",
    r"\d+\s*час(?:а|ов)?\b",
    r"\bобзор\b",
    r"\bреакция\b",
    r"\bтуториал\b",
    r"\bэпизод\s*\d*\b",
    r"\bплейлист\b",
    r"\bконцерт\b",
    r"\bфестиваль\b",
    r"\bвыпуск\s*\d+\b",
    r"\bпередача\s*\d*\b",
]
_STOPWORDS_RE = re.compile("|".join(_STOPWORD_PATTERNS), re.IGNORECASE)

# live_status у yt-dlp: 'is_live' | 'was_live' | 'is_upcoming' | 'not_live' | None
# was_live тоже выкидываем — это записанный концерт/стрим, обычно несколько песен подряд.
_BAD_LIVE_STATUSES = frozenset({"is_live", "was_live", "is_upcoming"})

# Длинное YouTube-видео без категории "Music" — почти наверняка не песня
# (vlog, обзор, документалка, лекция). 10 мин — порог отсечения.
_LONG_NON_MUSIC_THRESHOLD_SEC = 10 * 60


def is_single_song(
    *,
    title: str | None,
    duration: int | float | None,
    is_live: bool = False,
    live_status: str | None = None,
    categories: list[str] | None = None,
) -> bool:
    if is_live:
        return False
    if live_status in _BAD_LIVE_STATUSES:
        return False
    d: float | None = None
    if duration is not None:
        try:
            d = float(duration)
        except (TypeError, ValueError):
            d = None
        if d is not None and (d < MIN_DURATION_SEC or d > MAX_DURATION_SEC):
            return False
    if title and _STOPWORDS_RE.search(title):
        return False
    # YouTube soft-boost: если категории доступны и среди них нет 'Music',
    # длинное видео (> 10 мин) — почти наверняка не песня.
    if categories is not None and d is not None and d > _LONG_NON_MUSIC_THRESHOLD_SEC:
        has_music = any(c.lower() == "music" for c in categories)
        if not has_music:
            return False
    return True
