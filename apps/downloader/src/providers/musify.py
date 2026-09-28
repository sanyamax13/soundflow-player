"""musify.club provider — поиск + прямая mp3 ссылка через curl_cffi + BS4.

Структура страницы:
- /search?searchText=... → результаты с <a href="/track/...">title</a> и <a href="/artist/...">artist</a>
- /track/<slug> → страница трека, прямая ссылка /track/pl/{id}/{slug}.mp3 (data-url)

ВАЖНО (01.06.2026): musify.club фингерпринтит TLS (JA3) и режет обычные
HTTP-клиенты — httpx/openssl получал `DECRYPTION_FAILED_OR_BAD_RECORD_MAC`,
хотя сайт жив (браузерный запрос отдаёт 200). Ходим через curl_cffi с
impersonate="chrome" — он повторяет TLS-отпечаток Chrome и сайт пускает.

curl_cffi используем СИНХРОННО внутри asyncio.to_thread (как soundcloud/youtube
с yt_dlp): его AsyncSession не работает под уже-запущенным event loop'ом
uvicorn (находит 0 кандидатов), а sync Session в треде — стабильно.

Без авторизации, без Cloudflare.
"""
from __future__ import annotations
import asyncio
import logging
import re
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path
from urllib.parse import quote, quote_plus, urljoin, urlsplit

from bs4 import BeautifulSoup
from curl_cffi import requests as cffi

from ._fsutil import artist_subdir, make_filename
from ._validators import duration_off, is_alternate_version

log = logging.getLogger(__name__)

BASE = "https://musify.club"
# impersonate сам ставит правильный User-Agent + sec-ch-* + TLS-отпечаток Chrome.
# Пинним КОНКРЕТНУЮ версию, а не "chrome". В установленном curl_cffi алиас
# "chrome" указывал на старый отпечаток (~chrome116/110), на котором musify.club
# с 10.06.2026 рвёт TLS: h2 → curl 92 PROTOCOL_ERROR, http1.1 → curl 56
# BAD_DECRYPT; необработанное исключение валило весь /find-audio. Перебор показал:
# chrome120+/safari17/firefox133+ отдают 200. Берём chrome131 (свежий рабочий).
IMPERSONATE = "chrome131"
EXTRA_HEADERS = {"accept-language": "ru,en;q=0.9"}


@dataclass
class MusifyMatch:
    artist: str
    title: str
    track_url: str    # абсолютная ссылка на страницу трека
    download_url: str  # абсолютная прямая ссылка на mp3
    bitrate_kbps: int | None = None
    duration_sec: int | None = None
    score: float = 0.0
    is_alternate: bool = False


# С 28.09.2026 musify отдаёт «Проверка браузера…»: страница с JS, который считает djb2(n + M) и
# переходит на /__mzverify — тот ставит куку, дальше сайт пускает. Решаем то же самое без браузера.
_CHALLENGE = re.compile(r'var n="([^"]+)",M="([^"]+)"')


def _djb2(s: str) -> str:
    h = 5381
    for ch in s:
        h = ((h << 5) + h + ord(ch)) & 0xFFFFFFFF
    return format(h, "x")


def _get(session: "cffi.Session", url: str, **kw):
    """GET с прохождением «Проверки браузера» musify (кука остаётся в session)."""
    r = session.get(url, **kw)
    m = _CHALLENGE.search(r.text[:4000]) if "__mzverify" in r.text[:4000] else None
    if m is None:
        return r
    nonce, salt = m.groups()
    parts = urlsplit(url)
    back = parts.path + (("?" + parts.query) if parts.query else "")
    verify = (f"{BASE}/__mzverify?n={quote(nonce, safe='')}&t={_djb2(nonce + salt)}"
              f"&r={quote(back, safe='')}")
    session.get(verify, impersonate=kw.get("impersonate", IMPERSONATE), timeout=20)
    return session.get(url, **kw)


def _norm(s: str) -> str:
    return re.sub(r"[^a-zа-я0-9]+", "", s.lower())


def _similarity(a: str, b: str) -> float:
    return SequenceMatcher(None, _norm(a), _norm(b)).ratio()


def _parse_search(html: str) -> list[tuple[str, str, str]]:
    """Returns list of (track_href, title, artist)."""
    soup = BeautifulSoup(html, "html.parser")
    out: list[tuple[str, str, str]] = []
    for track_a in soup.select('a[href^="/track/"]'):
        href = track_a.get("href", "")
        if "/dl/" in href or not href.startswith("/track/"):
            continue
        title = track_a.get_text(strip=True)
        if not title or len(title) > 200:
            continue
        artist = ""
        parent = track_a.find_parent()
        for _ in range(4):
            if parent is None:
                break
            artist_a = parent.select_one('a[href^="/artist/"]')
            if artist_a:
                artist = artist_a.get_text(strip=True)
                break
            parent = parent.find_parent()
        if not artist:
            continue
        out.append((href, title, artist))
    return out


def _search_sync(session: "cffi.Session", query: str) -> list[tuple[str, str, str]]:
    url = f"{BASE}/search?searchText={quote_plus(query)}"
    r = _get(session, url, impersonate=IMPERSONATE, timeout=20)
    if r.status_code != 200:
        log.warning("musify search HTTP %d for %r", r.status_code, query)
        return []
    return _parse_search(r.text)


def _find_track_sync(artist: str, title: str,
                     expected_duration_sec: int | None = None) -> MusifyMatch | None:
    query = f"{artist} {title}"
    session = cffi.Session(headers=EXTRA_HEADERS)

    candidates = _search_sync(session, query)
    if not candidates:
        # Fallback: попробовать только title (артист часто разнится)
        candidates = _search_sync(session, title)
    if not candidates:
        return None

    # Скоринг: artist_sim + title_sim, требуем оба не ниже 0.55. Альтернативная
    # версия (remix/slowed/cover/...) больше НЕ отбрасывается условием — правило
    # Alex 23.09.2026 («не вместо оригинала, а вместе с оригиналом; убери условие
    # "не нашло — качает ремикс"»): небольшой штраф к score (не отказ), чтобы при
    # РАВНОМ совпадении победил обычный вариант, а не порядок в списке кандидатов.
    scored: list[tuple[float, str, str, str, bool]] = []
    for href, t, a in candidates:
        is_alt = is_alternate_version(t, title)[0]
        sa = _similarity(a, artist)
        st = _similarity(t, title)
        score = sa * 0.4 + st * 0.6
        if is_alt:
            score *= 0.9
        if sa >= 0.55 and st >= 0.55:
            scored.append((score, href, a, t, is_alt))
    if not scored:
        return None
    scored.sort(key=lambda x: x[0], reverse=True)
    best_score, best_href, best_artist, best_title, used_alt = scored[0]
    if used_alt:
        log.info("musify: взял альтернативную версию %r", best_title)

    track_url = urljoin(BASE, best_href)
    r = _get(session, track_url, impersonate=IMPERSONATE, timeout=20)
    if r.status_code != 200:
        return None
    soup = BeautifulSoup(r.text, "html.parser")
    # /track/dl/ требует логина. Используем streaming endpoint /track/pl/
    # из data-url (играет без авторизации, редиректит на CDN с sig).
    pl_el = soup.select_one('[data-url^="/track/pl/"]')
    if pl_el:
        download_url = urljoin(BASE, pl_el.get("data-url", ""))
    else:
        dl_a = soup.select_one('a[href*="/track/dl/"]')
        if not dl_a:
            return None
        download_url = urljoin(BASE, dl_a.get("href", ""))

    bitrate = None
    m = re.search(r"(\d{2,4})\s*К?[бБ]/с", r.text)
    if m:
        bitrate = int(m.group(1))
    duration = None
    dm = re.search(r"(\d{1,2}):(\d{2})", soup.get_text())
    if dm:
        duration = int(dm.group(1)) * 60 + int(dm.group(2))

    # Сверка длины с эталоном (Яндекс): если выбранный трек не той длины —
    # это не та версия, лучше отдать None (пусть сработает следующий источник).
    if duration_off(duration, expected_duration_sec):
        log.info(
            "musify: skip wrong-duration %r (%ss vs эталон %ss)",
            best_title, duration, expected_duration_sec,
        )
        return None

    return MusifyMatch(
        artist=best_artist,
        title=best_title,
        track_url=track_url,
        download_url=download_url,
        bitrate_kbps=bitrate,
        duration_sec=duration,
        score=best_score,
        is_alternate=used_alt,
    )


async def find_track(artist: str, title: str,
                     expected_duration_sec: int | None = None) -> MusifyMatch | None:
    """Ищет лучший match по musify для (artist, title)."""
    return await asyncio.to_thread(_find_track_sync, artist, title, expected_duration_sec)


def _download_match_sync(match: MusifyMatch, cache_dir: Path) -> tuple[str, MusifyMatch] | None:
    """Скачивает уже найденный MusifyMatch (без повторного поиска)."""
    cache_dir = Path(cache_dir)
    out_path = artist_subdir(cache_dir, match.artist) / make_filename(match.artist, match.title)

    session = cffi.Session(headers={**EXTRA_HEADERS, "referer": match.track_url})
    try:
        r = _get(session, match.download_url, impersonate=IMPERSONATE, timeout=60)
        if r.status_code != 200:
            log.warning("musify download HTTP %d for %r", r.status_code, match.download_url)
            return None
        with open(out_path, "wb") as f:
            f.write(r.content)
    except Exception as e:
        log.warning("musify download failed: %s", e)
        return None

    if out_path.stat().st_size < 100_000:
        try:
            out_path.unlink()
        except OSError:
            pass
        return None
    return (str(out_path), match)


async def download_match(match: MusifyMatch, cache_dir) -> tuple[str, MusifyMatch] | None:
    """Скачивает уже найденный match (без повторного поиска — экономит запросы
    к musify, который limit'ит частые обращения)."""
    return await asyncio.to_thread(_download_match_sync, match, cache_dir)


async def download_track(
    artist: str,
    title: str,
    cache_dir,  # Path
    expected_duration_sec: int | None = None,
) -> tuple[str, MusifyMatch] | None:
    """Полный цикл: search → download → save в cache_dir.
    Возвращает (file_path, MusifyMatch) или None если не нашли/не скачали.
    """
    def _full(a: str, t: str, cd, exp: int | None) -> tuple[str, MusifyMatch] | None:
        match = _find_track_sync(a, t, exp)
        if match is None:
            return None
        return _download_match_sync(match, cd)

    return await asyncio.to_thread(_full, artist, title, cache_dir, expected_duration_sec)
