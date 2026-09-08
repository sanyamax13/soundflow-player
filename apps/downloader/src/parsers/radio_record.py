"""Radio Record Russia electronic music live snapshot.

Дёргает https://www.radiorecord.ru/api/stations/now/ — официальный JSON
API радиостанции Record (электронная музыка, Россия). Endpoint отдаёт
~50 треков что сейчас играют на разных каналах Record (Russian Mix,
Pirate Station, Mix Mafia, House, Techno и т.д.).

Используется как доп. источник для вкладки «Электронная» в /charts.
Это не «чарт с позициями» — это live ротация на момент запроса. Обновляем
раз в час, в БД храним как обычный chart_entries с source='radio_record'.

Жанр всегда electronic — Record это electronic-music radio holding.
"""
from __future__ import annotations
import logging
from typing import Any

import httpx

URL = "https://www.radiorecord.ru/api/stations/now/"
log = logging.getLogger(__name__)


def fetch_radio_record() -> list[dict[str, Any]]:
    """Возвращает live snapshot Radio Record с position (по порядку), artist,
    title, cover_url, external_url.
    """
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        ),
        "Accept": "application/json",
    }
    r = httpx.get(URL, headers=headers, timeout=20, follow_redirects=True)
    r.raise_for_status()
    data = r.json()

    items: list[dict[str, Any]] = []
    seen_keys: set[str] = set()
    position = 0
    for entry in data.get("result") or []:
        t = entry.get("track") or {}
        artist_raw = (t.get("artist") or "").strip()
        title = (t.get("song") or "").strip()
        if not artist_raw or not title:
            continue
        # Record выдаёт artist через слэш для коллабораций: "GURU JOSH PROJECT/KLAAS".
        # Нормализуем в "GURU JOSH PROJECT, KLAAS".
        artist = ", ".join(a.strip() for a in artist_raw.split("/") if a.strip())

        # Dedup — на разных каналах может играть один и тот же трек.
        dedup_key = f"{artist.lower()}__{title.lower()}"
        if dedup_key in seen_keys:
            continue
        seen_keys.add(dedup_key)

        position += 1
        cover_url = t.get("image600") or t.get("image200") or t.get("image100")
        external_url = t.get("shareUrl") or t.get("itunesUrl")
        items.append({
            "position": position,
            "artist": artist,
            "title": title,
            "cover_url": cover_url,
            "external_url": external_url,
        })

    log.info("radio-record: %d unique tracks", len(items))
    return items
