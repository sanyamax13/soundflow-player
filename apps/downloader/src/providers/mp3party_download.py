"""Поиск и скачивание трека через mp3party.net.

Прямой direct-download mp3 — без торрентов, без логина. Используется как
fallback после rutracker и tapochek для треков которых ни SoundCloud, ни
торрент-трекеры не нашли (свежие синглы, нишевые исполнители).

Структура сайта:
- Поиск: GET /search?q=<query> → HTML со ссылками /music/<numeric_id>
- Страница трека: /music/<id> содержит метадату и mp3-ссылку в HTML
- Прямая mp3 ссылка: https://dl2.mp3party.net/online/<id>.mp3
- Кириллица должна быть URL-encoded (httpx делает это автоматически)
"""
from __future__ import annotations

import asyncio
import logging
import re
from dataclasses import dataclass
from pathlib import Path

import httpx

from ..config import config
from ._validators import (, validate_quality_metadata
    validate_audio_file,
    validate_full_track,
    validate_min_bitrate,
    validate_id3_match,
)
from .rutracker_album import _simplify_artist
from .soulseek_download import _FORBIDDEN_FS_CHARS, _file_matches, make_filename, normalize_key

log = logging.getLogger(__name__)

MP3PARTY_BASE = "https://mp3party.net"
MP3PARTY_SEARCH_URL = f"{MP3PARTY_BASE}/search"
MP3PARTY_DL_URL_TEMPLATE = "https://dl2.mp3party.net/online/{track_id}.mp3"
MP3PARTY_MIN_DURATION_SEC = 120
MP3PARTY_DOWNLOAD_TIMEOUT = 60.0
MP3PARTY_MAX_CANDIDATES_TO_TRY = 5

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

# Регексы для парсинга /search HTML
_RE_TRACK_LINK = re.compile(r'/music/(\d+)[a-z0-9-]*')
# На странице трека ищем metadata: title, artist, длительность
_RE_TRACK_TITLE = re.compile(r'<h1[^>]*>(.+?)</h1>', re.S)
_RE_DURATION = re.compile(r'(\d{1,2}):(\d{2})')


@dataclass
class Mp3partyDownloadResult:
    file_path: str
    bitrate_kbps: int | None
    duration_sec: int | None
    size_bytes: int
    source: str
    track_url: str


def _client() -> httpx.Client:
    return httpx.Client(
        timeout=30.0,
        headers={"User-Agent": UA, "Accept-Language": "ru-RU,ru;q=0.9"},
        follow_redirects=True,
    )


def _search_track_ids(client: httpx.Client, query: str) -> list[str]:
    """Поиск — возвращает уникальные numeric track_id'ы из /search?q="""
    try:
        r = client.get(MP3PARTY_SEARCH_URL, params={"q": query}, timeout=30.0)
    except Exception as exc:
        log.error("mp3party search failed: %s", exc)
        return []
    if r.status_code != 200:
        log.error("mp3party search HTTP %d", r.status_code)
        return []
    ids = list(dict.fromkeys(_RE_TRACK_LINK.findall(r.text)))
    return ids


def _fetch_track_meta(client: httpx.Client, track_id: str) -> tuple[str, str, int | None] | None:
    """Возвращает (artist, title, duration_sec) со страницы трека.

    Текст в <h1> обычно: "Артист — Название" или просто "Название". Длительность
    в HTML рядом со span.duration или похожим — берём первую mm:ss которую найдём
    после h1.
    """
    try:
        r = client.get(f"{MP3PARTY_BASE}/music/{track_id}", timeout=30.0)
    except Exception as exc:
        log.warning("mp3party track page failed %s: %s", track_id, exc)
        return None
    if r.status_code != 200:
        return None
    html = r.text
    m_h1 = _RE_TRACK_TITLE.search(html)
    title_full = (m_h1.group(1).strip() if m_h1 else "").strip()
    title_full = re.sub(r"<[^>]+>", "", title_full).strip()
    artist = ""
    title = title_full
    if " — " in title_full:
        artist, _, title = title_full.partition(" — ")
    elif " - " in title_full:
        artist, _, title = title_full.partition(" - ")
    duration_sec: int | None = None
    m_dur = _RE_DURATION.search(html[html.find("</h1>"):html.find("</h1>") + 2000] if "</h1>" in html else html[:5000])
    if m_dur:
        duration_sec = int(m_dur.group(1)) * 60 + int(m_dur.group(2))
    return artist.strip(), title.strip(), duration_sec


def _download_mp3(client: httpx.Client, track_id: str, target_path: Path) -> bool:
    """Скачивает mp3 с mp3party.net. Возвращает True только если файл прошёл
    общую validate_audio_file (размер + magic bytes). mp3party иногда отдаёт
    29-байтовое «failed to get file info: nil» вместо mp3 — отбрасываем."""
    url = MP3PARTY_DL_URL_TEMPLATE.format(track_id=track_id)
    try:
        with client.stream("GET", url, timeout=MP3PARTY_DOWNLOAD_TIMEOUT) as r:
            if r.status_code != 200:
                log.warning("mp3party dl: HTTP %d for %s", r.status_code, url)
                return False
            ctype = r.headers.get("content-type", "").lower()
            if "audio" not in ctype and "octet-stream" not in ctype:
                log.warning("mp3party dl: not audio content-type %s", ctype)
                return False
            with target_path.open("wb") as f:
                for chunk in r.iter_bytes(chunk_size=64 * 1024):
                    f.write(chunk)
    except Exception as exc:
        log.warning("mp3party dl failed %s: %s", url, exc)
        return False

    if not validate_audio_file(target_path, source="mp3party"):
        return False
    # Defense-in-depth: даже если провайдер думает что нашёл «полную» песню,
    # mp3party часто отдаёт 30-секундные обрывки. validate_full_track читает
    # реальную duration через mutagen и удаляет файл если <= 45с.
    if not validate_full_track(target_path, source="mp3party"):
        return False
    # Качество: mp3party иногда отдаёт 96-128k файлы — отсекаем (>=192 минимум)
    return validate_min_bitrate(target_path, source="mp3party", min_bitrate_kbps=192)


def _audio_meta(file_path: Path) -> tuple[int | None, int | None, int]:
    size_bytes = file_path.stat().st_size
    try:
        from mutagen import File as MutagenFile  # type: ignore

        m = MutagenFile(str(file_path))
        if m is None or m.info is None:
            return None, None, size_bytes
        bitrate = int(m.info.bitrate) // 1000 if m.info.bitrate else None
        duration = int(m.info.length) if m.info.length else None
        return bitrate, duration, size_bytes
    except Exception as exc:
        log.warning("mp3party mutagen failed for %s: %s", file_path, exc)
        return None, None, size_bytes


def _simplify_title(title: str) -> str:
    """Убирает скобки/квадраты для более широкого поиска.
    «Силуэт (из к/ф «Алиса в Стране Чудес»)» → «Силуэт»
    «КУКЛА (feat. VONAMOUR) [Remix 2026]» → «КУКЛА»
    """
    s = re.sub(r"\([^)]*\)", " ", title)
    s = re.sub(r"\[[^\]]*\]", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s or title


def _do_find_and_download(artist: str, title: str) -> Mp3partyDownloadResult | None:
    artist_key = normalize_key(artist)
    title_key = normalize_key(title)

    # Стратегия запросов: сначала полный, потом упрощённый. mp3party search
    # плохо работает с длинными названиями типа «Силуэт (из к/ф «Алиса в...)»
    queries = [f"{artist} {title}"]
    simple_q = f"{_simplify_artist(artist)} {_simplify_title(title)}"
    if simple_q != queries[0]:
        queries.append(simple_q)

    cache_dir = config.track_cache_dir
    cache_dir.mkdir(parents=True, exist_ok=True)

    with _client() as client:
        track_ids: list[str] = []
        for q in queries:
            log.info("mp3party: search %r", q)
            track_ids = _search_track_ids(client, q)
            if track_ids:
                if q != queries[0]:
                    log.info("mp3party: упрощённый запрос дал %d результатов", len(track_ids))
                break
        if not track_ids:
            log.info("mp3party: 0 search results после %d попыток", len(queries))
            return None
        log.info("mp3party: %d уникальных track_id из поиска", len(track_ids))

        for track_id in track_ids[:MP3PARTY_MAX_CANDIDATES_TO_TRY]:
            meta = _fetch_track_meta(client, track_id)
            if meta is None:
                continue
            page_artist, page_title, page_duration = meta
            combined = f"{page_artist} {page_title}"
            if not _file_matches(combined, artist_key, title_key):
                log.info(
                    "mp3party: skip %s (artist=%r title=%r не совпадает)",
                    track_id, page_artist, page_title,
                )
                continue
            if page_duration is not None and page_duration < MP3PARTY_MIN_DURATION_SEC:
                log.info("mp3party: skip %s (duration %ds < %d)", track_id, page_duration, MP3PARTY_MIN_DURATION_SEC)
                continue

            final_name = make_filename(artist, title, ext=".mp3")
            final_path = cache_dir / final_name
            if final_path.exists():
                try:
                    final_path.unlink()
                except OSError:
                    pass
            log.info("mp3party: качаю /music/%s в %s", track_id, final_name)
            if not _download_mp3(client, track_id, final_path):
                continue

            # ID3 match: mp3party иногда отдаёт ремейки/каверы под именем
            # оригинала (особенно для русских артистов с дубликатами имён).
            if not validate_id3_match(final_path, artist, title, source="mp3party"):
                continue

            bitrate, duration, size = _audio_meta(final_path)
            if duration is not None and duration < MP3PARTY_MIN_DURATION_SEC:
                log.info("mp3party: после скачки duration %ds < %d, удаляю", duration, MP3PARTY_MIN_DURATION_SEC)
                try:
                    final_path.unlink()
                except OSError:
                    pass
                continue

            return Mp3partyDownloadResult(
                file_path=str(final_path),
                bitrate_kbps=bitrate,
                duration_sec=duration,
                size_bytes=size,
                source="mp3party",
                track_url=f"{MP3PARTY_BASE}/music/{track_id}",
            )

    log.info("mp3party: ни один из %d кандидатов не подошёл", len(track_ids))
    return None


async def find_and_download(artist: str, title: str) -> Mp3partyDownloadResult | None:
    return await asyncio.to_thread(_do_find_and_download, artist, title)
