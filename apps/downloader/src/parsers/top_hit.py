"""Top-Hit Russia weekly radio chart parser.

Парсит https://tophit.ru/chart/top/radio/hits/ru/weekly — Top-100
радио-хитов России недельный, с жанровыми тегами на каждом треке.

Используется sidecar endpoint /tophit-chart. Возвращает 100 треков
с position, artist, title, language, genres (list), track_id для
последующей привязки обложки.

Структура HTML — Next.js с CSS modules. Классы стабильные, не меняются
между деплоями (например 'Row_row__7OlOi', 'Genres_genre__VTo0n') — это
hash от webpack, привязан к коду компонента; пока вёрстка не переделана,
hash тот же.

На случай если tophit поменяет hash — будем смотреть в логи и обновлять.
"""
from __future__ import annotations
import logging
import re
from typing import Any

import httpx
from bs4 import BeautifulSoup  # type: ignore[import-untyped]

URL = "https://tophit.ru/chart/top/radio/hits/ru/weekly"
log = logging.getLogger(__name__)

# CSS-module классы (текущие, май 2026). Регулярка по префиксу — если
# webpack hash меняется, прикручиваем новый суффикс не трогая логику.
RE_ROW = re.compile(r"\bRow_row__")
RE_TW = re.compile(r"\bRow_tw__")
RE_TITLE = re.compile(r"\bName_name__")
RE_ARTIST = re.compile(r"\bArtist_name-with-link__")
RE_ARTWORK = re.compile(r"\bRow_artwork__")
RE_GENRES = re.compile(r"\bRow_genres__")
RE_LANG = re.compile(r"\bLanguage_language__")


def fetch_tophit_chart() -> list[dict[str, Any]]:
    """Возвращает Top-100 радио-хитов России с position, artist, title,
    language, genres, track_id.

    genres — list[str] нормализованных в lowercase (e.g. ['pop', 'dance']).
    language — 'russian'|'english'|etc или None.
    """
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        ),
        "Accept-Language": "ru-RU,ru;q=0.9,en;q=0.8",
    }
    r = httpx.get(URL, headers=headers, timeout=30, follow_redirects=True)
    r.raise_for_status()
    soup = BeautifulSoup(r.text, "html.parser")

    items: list[dict[str, Any]] = []
    rows = soup.find_all("div", class_=RE_ROW)
    for row in rows:
        # Position (TW — This Week).
        tw_el = row.find("div", class_=RE_TW)
        if tw_el is None:
            continue
        pos_text = tw_el.get_text(strip=True)
        try:
            position = int(pos_text)
        except ValueError:
            continue
        if position < 1 or position > 200:
            continue

        # Title: <a class="Name_name__"><span>Title</span></a>
        title_el = row.find("a", class_=RE_TITLE)
        title = title_el.get_text(strip=True) if title_el else ""
        if not title:
            continue

        # Artist: <a class="Artist_name-with-link__">Artist</a>
        artist_el = row.find("a", class_=RE_ARTIST)
        artist = artist_el.get_text(strip=True) if artist_el else "Unknown"

        # Track ID for cover lookup (data-track-id on artwork div)
        artwork_el = row.find("div", class_=RE_ARTWORK)
        track_id: str | None = None
        if artwork_el is not None:
            track_id = artwork_el.get("data-track-id") or None

        # Language: <span title="Russian" class="fi fi-ru Language_language__">
        lang_el = row.find("span", class_=RE_LANG)
        language: str | None = None
        if lang_el is not None:
            language = (lang_el.get("title") or "").strip().lower() or None

        # Genres: <div class="Row_genres__"><div class="Genres_genre__">Pop</div>...</div>
        genres_wrapper = row.find("div", class_=RE_GENRES)
        genres: list[str] = []
        if genres_wrapper is not None:
            for g in genres_wrapper.find_all("div"):
                g_text = g.get_text(strip=True).lower()
                if g_text:
                    genres.append(g_text)

        items.append({
            "position": position,
            "artist": artist,
            "title": title,
            "language": language,
            "genres": genres,
            "track_id": track_id,
        })

    log.info("tophit-chart: parsed %d rows", len(items))
    return items
