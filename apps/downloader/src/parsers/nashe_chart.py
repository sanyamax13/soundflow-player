"""Russian rock chart parser — «Чартова Дюжина» Нашего Радио.

Парсит https://www.nashe.ru/chartova — голосование слушателей за
русский рок, обновляется еженедельно. Top-30+ треков.

HTML структура:
  <div class="chartova__item">
    <p class="chartova__track">Артист / <span class="chartova__track_song">Песня</span></p>
    <div class="chartova__vote">
      <button data-track="XXXX">Голосовать</button>
    </div>
  </div>

Позиция = индекс в DOM (1..N). Track ID = data-track attribute (внутренний
ID nashe.ru для голосования; используем как external_id чарт-записи).
"""
from __future__ import annotations
import logging
import re
from typing import Any

import httpx
from bs4 import BeautifulSoup  # type: ignore[import-untyped]

URL = "https://www.nashe.ru/chartova"
log = logging.getLogger(__name__)


def fetch_nashe_chartova() -> list[dict[str, Any]]:
    """Возвращает русский рок-чарт с position, artist, title, track_id.
    cover_url и external_url не отдаём (на странице нет обложек треков).
    """
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        ),
        "Accept-Language": "ru-RU,ru;q=0.9",
    }
    r = httpx.get(URL, headers=headers, timeout=30, follow_redirects=True)
    r.raise_for_status()
    soup = BeautifulSoup(r.text, "html.parser")

    items: list[dict[str, Any]] = []
    chart_items = soup.find_all("div", class_="chartova__item")
    for idx, item in enumerate(chart_items, start=1):
        track_p = item.find("p", class_="chartova__track")
        if track_p is None:
            continue
        song_span = track_p.find("span", class_="chartova__track_song")
        if song_span is None:
            continue
        title = song_span.get_text(strip=True)
        # Артист = текст в <p> ДО <span>. Используем contents[0] — это
        # первый TextNode перед <span>. Формат: "Артист / "
        if not track_p.contents:
            continue
        artist_raw = str(track_p.contents[0]).strip()
        # Убираем хвостовой " /" и пробелы
        artist = re.sub(r"\s*/\s*$", "", artist_raw).strip()
        if not artist or not title:
            continue

        # track_id для голосования (внутренний ID nashe.ru)
        track_id: str | None = None
        btn = item.find("button", class_="chartova__button_vote")
        if btn is not None:
            tid = btn.get("data-track")
            if tid:
                track_id = str(tid)

        external_url = (
            f"https://www.nashe.ru/chartova#track-{track_id}" if track_id else URL
        )

        items.append({
            "position": idx,
            "artist": artist,
            "title": title,
            "cover_url": None,
            "external_url": external_url,
            "track_id": track_id,
        })

    log.info("nashe-chartova: parsed %d items", len(items))
    return items
