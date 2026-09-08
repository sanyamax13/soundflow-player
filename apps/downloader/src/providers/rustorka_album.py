"""Поиск и скачивание альбомов с rustorka.net (движок TorrentPier).

Добавлен 08.09.2026 по просьбе Alex («Rustorka давай ещё»). Поиск и
скачивание требуют логина — заходим по cookie из браузера
(config.rustorka_cookie), как nnmclub/rutracker.

Схема TorrentPier: tracker.php?nm=<query> (UTF-8), страница cp1251,
скачивание .torrent — dl.php?t=<topic_id>.

ВНИМАНИЕ: разметку rustorka вживую не сверяли — парсер написан по типовому
TorrentPier. Не совпали regex → _do_search вернёт [] (не падение). Когда
Alex принесёт cookie — проверить на реальном HTML и поправить regex.
"""
from __future__ import annotations

import logging
import re
import time
from typing import Any

from curl_cffi import requests as cffi_requests

from ..config import config

log = logging.getLogger(__name__)

RUSTORKA_BASE = "https://rustorka.net"
RUSTORKA_SEARCH_URL = f"{RUSTORKA_BASE}/tracker.php"
RUSTORKA_TOPIC_URL = f"{RUSTORKA_BASE}/viewtopic.php"
RUSTORKA_DL_URL = f"{RUSTORKA_BASE}/dl.php"
RUSTORKA_HTML_ENCODING = "cp1251"

# Строка результата TorrentPier: <tr class="tor tCenter hl-tr" ...> ... </tr>
_RE_ROW = re.compile(r'<tr[^>]*class="[^"]*\btor\b[^"]*"[^>]*>.*?</tr>', re.S)
_RE_TID = re.compile(r'viewtopic\.php\?t=(\d+)')
_RE_TITLE = re.compile(r'data-topic_id="\d+"[^>]*>(.*?)</a>|class="tt-text"[^>]*>(.*?)</a>', re.S)
_RE_DL = re.compile(r'dl\.php\?t=(\d+)')
_RE_SIZE = re.compile(r'data-size="(\d+)"|<u>(\d+)</u>')
_RE_SEED = re.compile(r'class="[^"]*\bseed(?:er|med)?\b[^"]*"[^>]*>\s*(?:<b>)?(-?\d+)')
_RE_LEECH = re.compile(r'class="[^"]*\bleech(?:er|med)?\b[^"]*"[^>]*>\s*(?:<b>)?(\d+)')

_session: "cffi_requests.Session | None" = None
_RETRY = 4


def available() -> bool:
    return bool((config.rustorka_cookie or "").strip())


def _ensure_session() -> "cffi_requests.Session | None":
    global _session
    if _session is not None:
        return _session
    cookie = (config.rustorka_cookie or "").strip()
    if not cookie:
        log.error("rustorka: cookie не настроен (RUSTORKA_COOKIE)")
        return None
    s = cffi_requests.Session(impersonate="chrome")
    for part in cookie.split(";"):
        name, sep, val = part.strip().partition("=")
        if sep and name:
            s.cookies.set(name.strip(), val.strip(), domain=".rustorka.net")
    _session = s
    log.info("rustorka: cookie-сессия, куки: %s", [c.name for c in s.cookies.jar])
    return s


def _get(s: "cffi_requests.Session", url: str, *, timeout: float = 15.0):
    last: Exception | None = None
    for i in range(_RETRY):
        try:
            return s.get(url, timeout=timeout, headers={"Accept-Language": "ru-RU,ru;q=0.9"})
        except Exception as exc:  # noqa: BLE001
            last = exc
            if i < _RETRY - 1:
                time.sleep(1 + i)
    log.warning("rustorka GET исчерпал попытки (%s): %s", url, last)
    return None


def _strip(s: str) -> str:
    import html as _h
    return _h.unescape(re.sub(r"<[^>]+>", "", s)).strip()


def _parse(html: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for row in _RE_ROW.findall(html):
        m_tid = _RE_TID.search(row)
        m_title = _RE_TITLE.search(row)
        m_dl = _RE_DL.search(row)
        m_size = _RE_SIZE.search(row)
        if not (m_tid and m_title and m_size):
            continue
        title = _strip(m_title.group(1) or m_title.group(2) or "")
        size = int(m_size.group(1) or m_size.group(2) or 0)
        m_s = _RE_SEED.search(row)
        m_l = _RE_LEECH.search(row)
        tid = m_dl.group(1) if m_dl else m_tid.group(1)
        out.append({
            "title": title,
            "topic_id": m_tid.group(1),
            "topic_url": f"{RUSTORKA_TOPIC_URL}?t={m_tid.group(1)}",
            "torrent_url": f"{RUSTORKA_DL_URL}?t={tid}",
            "size_bytes": size,
            "seeders": max(0, int(m_s.group(1))) if m_s else 0,
            "leechers": int(m_l.group(1)) if m_l else 0,
        })
    return out


def _do_search(artist: str) -> list[dict[str, Any]]:
    s = _ensure_session()
    if s is None:
        return []
    from urllib.parse import quote
    url = f"{RUSTORKA_SEARCH_URL}?nm={quote(artist)}"
    r = _get(s, url)
    if r is None or r.status_code != 200:
        log.warning("rustorka search HTTP %s", getattr(r, "status_code", "?"))
        return []
    try:
        html = r.content.decode(RUSTORKA_HTML_ENCODING, errors="replace")
    except Exception as exc:
        log.warning("rustorka decode: %s", exc)
        return []
    res = _parse(html)
    log.info("rustorka: %r → %d результатов", artist, len(res))
    return res


def _download_torrent_bytes(torrent_url: str) -> bytes | None:
    s = _ensure_session()
    if s is None:
        return None
    r = _get(s, torrent_url, timeout=30.0)
    if r is None or r.status_code != 200:
        log.warning("rustorka .torrent HTTP %s", getattr(r, "status_code", "?"))
        return None
    if "torrent" not in r.headers.get("content-type", "").lower() and not r.content.startswith(b"d"):
        log.warning("rustorka .torrent: не торрент (протухла кука?)")
        return None
    return r.content
