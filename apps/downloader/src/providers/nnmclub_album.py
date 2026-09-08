"""Поиск и скачивание альбомов с nnmclub.to через qBittorrent (07.06.2026).

NNM-Club — phpBB2-трекер с большим музыкальным разделом (mp3 + Lossless). Поиск
работает анонимно, но скачивание .torrent требует логина (там капча) — заходим
по «пропуску» (cookie из браузера, config.nnmclub_cookie), как rutracker.

Особенности vs rutor:
- Страница в cp1251 (декодируем), НО поисковый запрос nm= шлём в UTF-8 —
  cp1251-запрос даёт 0 результатов (проверено).
- Скачивание: download.php?id=<id> с cookie-сессией.
- Берём только MP3-альбомы. FLAC/Lossless пока не поддержан сканером
  (_read_album_tracks ищет *.mp3) — это будущее расширение.

Переиспользует qBT/scan helpers из rutracker_album.py — `_qbt_client`,
`_wait_torrent_*`, `_torrent_has_target`, `_read_album_tracks`,
`_find_target_track`, `_simplify_artist`, `_download_lock`.
"""
from __future__ import annotations

import asyncio
import logging
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import quote

import qbittorrentapi  # type: ignore[import-untyped]
from curl_cffi import requests as cffi_requests

from ..config import config
from .rutracker_album import (
    AlbumTrack,
    MAX_CANDIDATES_TO_TRY,
    QBT_CATEGORY,
    _download_lock,
    _find_target_track,
    _qbt_client,
    _read_album_tracks,
    _simplify_artist,
    _torrent_has_target,
    _wait_torrent_complete,
    _wait_torrent_metadata,
)
from .soulseek_download import _file_matches, normalize_key
from ._validators import is_compilation_title

log = logging.getLogger(__name__)

NNM_BASE = "https://nnmclub.to/forum"
NNM_SEARCH_URL = f"{NNM_BASE}/tracker.php"
NNM_DOWNLOAD_URL = f"{NNM_BASE}/download.php"
NNM_TOPIC_URL = f"{NNM_BASE}/viewtopic.php"
NNM_HTML_ENCODING = "cp1251"

MIN_ALBUM_SIZE = 30 * 1024 * 1024
MAX_ALBUM_SIZE = 300 * 1024 * 1024
CFFI_RETRY = 4

# Строка результата tracker.php: <tr class="prow1"> / "prow2" (зебра).
_RE_ROW = re.compile(r'<tr class="prow[12]">.*?</tr>', re.S)
_RE_TID = re.compile(r'viewtopic\.php\?t=(\d+)')
_RE_TITLE = re.compile(r'topictitle"[^>]*><b>(.*?)</b>', re.S)
_RE_DL = re.compile(r'download\.php\?id=(\d+)')
_RE_SIZE = re.compile(r'<u>(\d+)</u>')  # точный размер в байтах (идёт раньше даты)
_RE_SEEDS = re.compile(r'class="seedmed"[^>]*><b>(-?\d+)')
_RE_LEECH = re.compile(r'class="leechmed"[^>]*><b>(\d+)')

_nnm_session: "cffi_requests.Session | None" = None


@dataclass
class NnmDownloadResult:
    target_file_path: str
    album_dir: str
    target_meta: AlbumTrack
    forum_url: str
    all_tracks: list[AlbumTrack] = field(default_factory=list)


def _ensure_session() -> "cffi_requests.Session | None":
    """curl_cffi-сессия с cookie из браузера (вход в NNM-Club требует капчу).
    config.nnmclub_cookie вида "phpbb2mysql_4_data=...; phpbb2mysql_4_sid=..."."""
    global _nnm_session
    if _nnm_session is not None:
        return _nnm_session
    cookie = (config.nnmclub_cookie or "").strip()
    if not cookie:
        log.error("nnmclub: cookie не настроен (NNMCLUB_COOKIE)")
        return None
    session = cffi_requests.Session(impersonate="chrome")
    for part in cookie.split(";"):
        name, sep, val = part.strip().partition("=")
        if sep and name:
            session.cookies.set(name.strip(), val.strip(), domain=".nnmclub.to")
    _nnm_session = session
    log.info("nnmclub: cookie-сессия, куки: %s", [c.name for c in session.cookies.jar])
    return session


def _force_resession() -> None:
    global _nnm_session
    _nnm_session = None
    _ensure_session()


def _cffi_get(session: "cffi_requests.Session", url: str, *, timeout: float = 15.0):
    last_exc: Exception | None = None
    for attempt in range(CFFI_RETRY):
        try:
            return session.get(url, timeout=timeout)
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
            msg = str(exc).lower()
            transient = any(
                s in msg
                for s in ("invalid library", "tls connect", "unexpected_eof",
                          "curl: (35)", "curl: (56)", "curl: (92)")
            )
            if transient and attempt < CFFI_RETRY - 1:
                time.sleep(1 + attempt)
                continue
            log.warning("nnmclub GET failed (%s): %s", url, exc)
            return None
    log.warning("nnmclub GET: исчерпаны попытки (%s): %s", url, last_exc)
    return None


def _http_get_search(session: "cffi_requests.Session", query: str) -> str | None:
    # Запрос nm= в UTF-8 (cp1251 даёт 0), страница приходит в cp1251.
    url = f"{NNM_SEARCH_URL}?nm={quote(query)}"
    r = _cffi_get(session, url, timeout=20.0)
    if r is None:
        return None
    if r.status_code != 200:
        log.warning("nnmclub search HTTP %d for %r", r.status_code, query)
        return None
    try:
        return r.content.decode(NNM_HTML_ENCODING, errors="replace")
    except Exception as exc:  # noqa: BLE001
        log.warning("nnmclub html decode failed: %s", exc)
        return None


def _strip_tags(s: str) -> str:
    import html as _html
    return _html.unescape(re.sub(r"<[^>]+>", "", s)).strip()


def _parse_results(html: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for row in _RE_ROW.findall(html):
        m_tid = _RE_TID.search(row)
        m_title = _RE_TITLE.search(row)
        m_dl = _RE_DL.search(row)
        m_size = _RE_SIZE.search(row)
        m_seeds = _RE_SEEDS.search(row)
        m_leech = _RE_LEECH.search(row)
        if not (m_tid and m_title and m_dl and m_size):
            continue
        try:
            size_bytes = int(m_size.group(1))
        except ValueError:
            continue
        out.append(
            {
                "title": _strip_tags(m_title.group(1)),
                "topic_id": m_tid.group(1),
                "topic_url": f"{NNM_TOPIC_URL}?t={m_tid.group(1)}",
                "download_id": m_dl.group(1),
                "size_bytes": size_bytes,
                "seeders": int(m_seeds.group(1)) if m_seeds else 0,
                "leechers": int(m_leech.group(1)) if m_leech else 0,
            }
        )
    return out


def _download_torrent_bytes(session: "cffi_requests.Session", download_id: str) -> bytes | None:
    url = f"{NNM_DOWNLOAD_URL}?id={download_id}"
    r = _cffi_get(session, url, timeout=25.0)
    if r is None:
        return None
    if r.status_code != 200:
        log.warning("nnmclub .torrent HTTP %d for id=%s", r.status_code, download_id)
        return None
    ctype = r.headers.get("content-type", "").lower()
    if "torrent" not in ctype and not r.content.startswith(b"d"):
        log.warning("nnmclub .torrent: не торрент (ctype=%s) — возможно протух cookie", ctype)
        return None
    return r.content


def _do_search(session: "cffi_requests.Session", artist: str) -> list[dict[str, Any]]:
    queries = [artist]
    simplified = _simplify_artist(artist)
    if simplified != artist:
        queries.append(simplified)
    for q in queries:
        html = _http_get_search(session, q)
        if html is None:
            continue
        results = _parse_results(html)
        if results:
            if q != artist:
                log.info("nnmclub: упрощённый запрос %r дал %d", q, len(results))
            return results
    return []


def _filter_candidates(results: list[dict[str, Any]], artist_key: str) -> list[dict[str, Any]]:
    """MP3 + размер 30-300 МБ + сидеры > 0 + артист в названии, не сборник."""
    out = []
    for r in results:
        title = str(r.get("title", ""))
        size = int(r.get("size_bytes") or 0)
        seeders = int(r.get("seeders") or 0)
        if "MP3" not in title.upper():  # FLAC/Lossless пока не сканируем
            continue
        if size < MIN_ALBUM_SIZE or size > MAX_ALBUM_SIZE:
            continue
        if seeders < 1:
            continue
        if not _file_matches(title, artist_key, artist_key):
            continue
        if is_compilation_title(title):
            log.info("nnmclub: пропускаю сборник: %r", title)
            continue
        out.append(r)
    out.sort(key=lambda r: int(r.get("seeders") or 0), reverse=True)
    return out


def _add_torrent_paused(qbt: qbittorrentapi.Client, torrent_bytes: bytes) -> None:
    try:
        qbt.torrent_categories.create_category(name=QBT_CATEGORY, save_path=str(config.albums_dir))
    except Exception:
        pass
    qbt.torrents.add(
        torrent_files=[torrent_bytes],
        save_path=str(config.albums_dir),
        category=QBT_CATEGORY,
        is_paused=True,
    )


def _do_find_and_download(
    artist: str,
    title: str,
    rejected_source_urls: set[str] | None = None,
) -> NnmDownloadResult | None:
    rejected = rejected_source_urls or set()
    if not config.qbt_user or not config.qbt_pass:
        log.error("nnmclub: QBT_USER/QBT_PASS не настроены")
        return None
    session = _ensure_session()
    if session is None:
        return None
    artist_key = normalize_key(artist)
    title_key = normalize_key(title)

    log.info("nnmclub: search by artist=%r (target track=%r)", artist, title)
    results = _do_search(session, artist)
    if not results:
        log.info("nnmclub: 0 search results")
        return None
    candidates = _filter_candidates(results, artist_key)
    log.info("nnmclub: %d/%d кандидатов (MP3 + size + seeders)", len(candidates), len(results))
    if not candidates:
        return None

    qbt = _qbt_client()
    qbt.auth_log_in()
    config.albums_dir.mkdir(parents=True, exist_ok=True)

    for cand in candidates[:MAX_CANDIDATES_TO_TRY]:
        if cand["topic_url"] in rejected:
            log.info("nnmclub: rejected-source skip: %s — %s", artist, cand["topic_url"])
            continue
        log.info(
            "nnmclub: try %s (%d MB, %d seeders)",
            cand["title"], cand["size_bytes"] // (1024 * 1024), cand["seeders"],
        )
        torrent_bytes = _download_torrent_bytes(session, cand["download_id"])
        if not torrent_bytes:
            continue
        before = {t.hash for t in qbt.torrents.info(category=QBT_CATEGORY)}
        try:
            _add_torrent_paused(qbt, torrent_bytes)
        except qbittorrentapi.Conflict409Error:
            log.info("nnmclub: torrent уже есть в qBittorrent, скип")
            continue
        except Exception as exc:  # noqa: BLE001
            log.warning("nnmclub: qbt.add failed: %s", exc)
            continue

        new_hash = None
        for _ in range(20):
            time.sleep(1)
            after = qbt.torrents.info(category=QBT_CATEGORY)
            for t in after:
                if t.hash not in before:
                    new_hash = t.hash
                    break
            if new_hash:
                break
        if not new_hash:
            log.warning("nnmclub: не нашёл новый торрент в qBittorrent")
            continue

        files = _wait_torrent_metadata(qbt, new_hash)
        if files is None:
            log.warning("nnmclub: metadata не получены, удаляю %s", new_hash)
            try:
                qbt.torrents.delete(torrent_hashes=new_hash, delete_files=True)
            except Exception:
                pass
            continue
        if not _torrent_has_target(files, title_key):
            log.info("nnmclub: в torrent нет mp3 '%s' (%d файлов), удаляю", title, len(files))
            try:
                qbt.torrents.delete(torrent_hashes=new_hash, delete_files=True)
            except Exception:
                pass
            continue
        log.info("nnmclub: подходящий mp3 есть, качаю полностью")

        try:
            qbt.torrents.start(torrent_hashes=new_hash)
        except Exception as exc:  # noqa: BLE001
            log.warning("nnmclub: resume failed %s: %s", new_hash, exc)
            continue

        info = _wait_torrent_complete(qbt, new_hash)
        if info is None:
            try:
                qbt.torrents.delete(torrent_hashes=new_hash, delete_files=True)
            except Exception:
                pass
            continue

        try:
            qbt.torrents.stop(torrent_hashes=new_hash)
        except Exception:
            pass

        content_path = info.get("content_path") or info.get("save_path")
        album_dir = Path(content_path) if content_path else config.albums_dir
        if album_dir.is_file():
            album_dir = album_dir.parent

        all_tracks = _read_album_tracks(album_dir)
        log.info("nnmclub: в альбоме %d mp3 (%s)", len(all_tracks), album_dir)
        target = _find_target_track(all_tracks, artist_key, title_key)
        if target is None:
            log.info("nnmclub: целевой трек %r не найден, следующий кандидат", title)
            continue

        log.info("nnmclub: нашли %s", target.file_path)
        return NnmDownloadResult(
            target_file_path=target.file_path,
            album_dir=str(album_dir),
            target_meta=target,
            forum_url=cand["topic_url"],
            all_tracks=all_tracks,
        )

    log.info("nnmclub: ни один из %d кандидатов не дал нужный трек", len(candidates))
    return None


async def find_and_download(
    artist: str,
    title: str,
    *,
    rejected_source_urls: set[str] | None = None,
) -> NnmDownloadResult | None:
    async with _download_lock:
        return await asyncio.to_thread(_do_find_and_download, artist, title, rejected_source_urls)
