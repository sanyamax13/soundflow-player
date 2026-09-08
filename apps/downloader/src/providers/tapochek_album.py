"""Поиск и скачивание альбомов с tapochek.net через qBittorrent.

Третий провайдер после SoundCloud и rutracker. Структура tapochek похожа на
rutracker (phpBB-форум, login + tracker.php + download.php), но:
- Login проще (нет CSRF)
- Каждый результат имеет 2 разных id: topic_id (viewtopic.php) и dl_id (download.php)

Используем для треков которые SoundCloud и rutracker не покрыли — обычно русский
поп/рок где tapochek специализированнее.
"""
from __future__ import annotations

import asyncio
import logging
import re
import time
from pathlib import Path
from typing import Any

import httpx
import qbittorrentapi  # type: ignore[import-untyped]

from ..config import config
from .rutracker_album import (
    QBT_CATEGORY,
    DOWNLOAD_TIMEOUT_SEC,
    METADATA_TIMEOUT_SEC,
    POLL_INTERVAL_SEC,
    MIN_ALBUM_SIZE,
    MAX_ALBUM_SIZE,
    MAX_CANDIDATES_TO_TRY,
    AlbumTrack,
    RutrackerDownloadResult as TapochekDownloadResult,  # одинаковая структура
    _qbt_client,
    _wait_torrent_complete,
    _wait_torrent_metadata,
    _torrent_has_target,
    _read_album_tracks,
    _find_target_track,
    _filter_candidates,
    _simplify_artist,
    _cp1251_search_url,
)
from .soulseek_download import normalize_key

log = logging.getLogger(__name__)

TAPOCHEK_BASE = "https://tapochek.net"
TAPOCHEK_LOGIN_URL = f"{TAPOCHEK_BASE}/login.php"
TAPOCHEK_SEARCH_URL = f"{TAPOCHEK_BASE}/tracker.php"
TAPOCHEK_DOWNLOAD_URL = f"{TAPOCHEK_BASE}/download.php"
TAPOCHEK_TOPIC_URL = f"{TAPOCHEK_BASE}/viewtopic.php"
TAPOCHEK_HTML_ENCODING = "windows-1251"

_RE_THREADS = re.compile(r'<tr class="tCenter"[^>]*id="tor_\d+".*?</tr>', re.S)
_RE_TORRENT = re.compile(
    r'<a class="genmed[^"]*" href="\./viewtopic\.php\?t=(?P<topic_id>\d+)">\s*(?P<title>.+?)</a>'
    r".+?"
    r"<u>(?P<size>\d+)</u>"
    r".+?"
    r'href="\./download\.php\?id=(?P<dl_id>\d+)"'
    r".+?"
    r'<span class="seed"><b>(?P<seeds>\d+)</b></span>'
    r".+?"
    r'<span class="leech"><b>(?P<leech>\d+)</b></span>',
    re.S,
)

_tapochek_client: httpx.Client | None = None
_download_lock = asyncio.Lock()


def _ensure_session(username: str, password: str) -> httpx.Client | None:
    global _tapochek_client
    if _tapochek_client is not None:
        return _tapochek_client
    client = httpx.Client(
        timeout=30.0,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            )
        },
        follow_redirects=True,
    )
    # Tapochek login: без CSRF — простой POST с login_username/login_password
    try:
        r = client.post(
            TAPOCHEK_LOGIN_URL,
            data={
                "login_username": username,
                "login_password": password,
                "redirect": "index.php",
                "login": "Вход",
                "autologin": "on",
            },
        )
    except Exception as exc:
        log.error("tapochek login failed: %s", exc)
        return None
    if "bb_data" not in client.cookies:
        log.error("tapochek login: cookie bb_data не получен (status=%d)", r.status_code)
        return None
    log.info("tapochek login OK")
    _tapochek_client = client
    return client


def _strip_html(s: str) -> str:
    import html as _html
    s = re.sub(r"<[^>]+>", "", s)
    return _html.unescape(s).strip()


def _http_get_tap(query: str) -> str | None:
    client = _tapochek_client
    if client is None:
        return None
    try:
        r = client.get(_cp1251_search_url(TAPOCHEK_SEARCH_URL, query), timeout=10.0)
    except Exception as exc:
        log.error("tapochek search failed: %s", exc)
        return None
    if r.status_code != 200:
        log.error("tapochek search HTTP %d", r.status_code)
        return None
    try:
        return r.content.decode(TAPOCHEK_HTML_ENCODING, errors="replace")
    except Exception as exc:
        log.error("tapochek html decode failed: %s", exc)
        return None


def _parse_tap_html(html: str) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for thread_html in _RE_THREADS.findall(html):
        m = _RE_TORRENT.search(thread_html)
        if not m:
            continue
        d = m.groupdict()
        try:
            results.append(
                {
                    "fileName": _strip_html(d["title"]),
                    "fileSize": int(d["size"]),
                    "nbSeeders": max(0, int(d["seeds"])),
                    "nbLeechers": int(d["leech"]),
                    "fileUrl": f"{TAPOCHEK_DOWNLOAD_URL}?id={d['dl_id']}",
                    "descrLink": f"{TAPOCHEK_TOPIC_URL}?t={d['topic_id']}",
                }
            )
        except (KeyError, ValueError) as exc:
            log.debug("skip torrent: %s", exc)
    return results


def _do_search(artist: str) -> list[dict[str, Any]]:
    """Поиск на tapochek через нашу httpx-сессию.

    Стратегия как у rutracker — full, потом simplified для составных артистов.
    """
    if _tapochek_client is None:
        log.error("tapochek_album: session not initialized")
        return []
    queries = [artist]
    simplified = _simplify_artist(artist)
    if simplified != artist:
        queries.append(simplified)
    for q in queries:
        html = _http_get_tap(q)
        if html is None:
            continue
        results = _parse_tap_html(html)
        if results:
            if q != artist:
                log.info("tapochek_album: упрощённый запрос %r дал %d", q, len(results))
            return results
    return []


def _download_torrent_file(torrent_url: str) -> bytes | None:
    """Скачивает .torrent с tapochek (нужны куки от login). Retry на сетевых сбоях."""
    client = _tapochek_client
    if client is None:
        log.error("tapochek session not initialized")
        return None
    delays = [0, 5, 10]
    for i, delay in enumerate(delays):
        if delay:
            time.sleep(delay)
        try:
            r = client.get(torrent_url, timeout=30.0)
        except Exception as exc:
            log.warning("tapochek .torrent attempt %d failed: %s", i + 1, exc)
            continue
        if r.status_code == 200:
            ctype = r.headers.get("content-type", "").lower()
            if "torrent" not in ctype and not r.content.startswith(b"d"):
                log.error("tapochek .torrent: not a torrent file (ctype=%s)", ctype)
                return None
            return r.content
        if r.status_code in (521, 522, 524, 502, 503):
            log.warning("tapochek .torrent attempt %d: HTTP %d, retry...", i + 1, r.status_code)
            continue
        log.error("tapochek .torrent: HTTP %d for %s", r.status_code, torrent_url)
        return None
    log.error("tapochek .torrent: все попытки не удались для %s", torrent_url)
    return None


def _do_find_and_download(
    artist: str,
    title: str,
    rejected_source_urls: set[str] | None = None,
) -> TapochekDownloadResult | None:
    rejected = rejected_source_urls or set()
    if not config.tapochek_user or not config.tapochek_pass:
        log.error("tapochek_album: TAPOCHEK_USER/TAPOCHEK_PASS не настроены")
        return None
    artist_key = normalize_key(artist)
    title_key = normalize_key(title)

    if _ensure_session(config.tapochek_user, config.tapochek_pass) is None:
        return None

    log.info("tapochek_album: search by artist=%r (target track=%r)", artist, title)
    results = _do_search(artist)
    if not results:
        log.info("tapochek_album: 0 search results")
        return None
    candidates = _filter_candidates(results, artist_key)
    log.info(
        "tapochek_album: %d/%d отфильтрованных кандидатов (mp3 + size + seeders)",
        len(candidates), len(results),
    )
    if not candidates:
        return None

    qbt = _qbt_client()
    qbt.auth_log_in()
    config.albums_dir.mkdir(parents=True, exist_ok=True)

    for cand in candidates[:MAX_CANDIDATES_TO_TRY]:
        torrent_url = cand.get("fileUrl") or ""
        descr_link = str(cand.get("descrLink") or "")
        if descr_link in rejected:
            log.info(
                "tapochek_album: rejected-source skip: %s — %s source_url=%s",
                artist, title, descr_link,
            )
            continue
        log.info(
            "tapochek_album: try %s (%d MB, %d seeders)",
            cand.get("fileName"),
            int(cand.get("fileSize") or 0) // (1024 * 1024),
            int(cand.get("nbSeeders") or 0),
        )
        torrent_bytes = _download_torrent_file(torrent_url)
        if not torrent_bytes:
            continue

        before = {t.hash for t in qbt.torrents.info(category=QBT_CATEGORY)}
        try:
            qbt.torrent_categories.create_category(name=QBT_CATEGORY, save_path=str(config.albums_dir))
        except Exception:
            pass
        try:
            qbt.torrents.add(
                torrent_files=[torrent_bytes],
                save_path=str(config.albums_dir),
                category=QBT_CATEGORY,
                is_paused=True,
            )
        except qbittorrentapi.Conflict409Error:
            log.info("tapochek_album: torrent уже есть в qBittorrent, скип")
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
            log.warning("tapochek_album: новый торрент не появился")
            continue

        files = _wait_torrent_metadata(qbt, new_hash)
        if files is None:
            log.warning("tapochek_album: metadata не получены, удаляю")
            try:
                qbt.torrents.delete(torrent_hashes=new_hash, delete_files=True)
            except Exception:
                pass
            continue
        if not _torrent_has_target(files, title_key):
            log.info(
                "tapochek_album: в torrent нет mp3 с именем '%s' (всего %d файлов), удаляю",
                title, len(files),
            )
            try:
                qbt.torrents.delete(torrent_hashes=new_hash, delete_files=True)
            except Exception:
                pass
            continue

        log.info("tapochek_album: в torrent есть подходящий mp3, начинаю полную скачку")
        try:
            qbt.torrents.start(torrent_hashes=new_hash)
        except Exception as exc:
            log.warning("tapochek_album: resume не сработал: %s", exc)
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
        log.info("tapochek_album: в альбоме %d mp3 (папка %s)", len(all_tracks), album_dir)
        target = _find_target_track(all_tracks, artist_key, title_key)
        if target is None:
            log.info("tapochek_album: target не найден в альбоме (после tags), пробуем дальше")
            continue

        log.info("tapochek_album: нашли %s в альбоме", target.file_path)
        return TapochekDownloadResult(
            target_file_path=target.file_path,
            album_dir=str(album_dir),
            target_meta=target,
            forum_url=str(cand.get("descrLink") or ""),
            all_tracks=all_tracks,
        )

    log.info("tapochek_album: ни один из %d кандидатов не подошёл", len(candidates))
    return None


async def find_and_download(
    artist: str,
    title: str,
    *,
    rejected_source_urls: set[str] | None = None,
) -> TapochekDownloadResult | None:
    async with _download_lock:
        return await asyncio.to_thread(_do_find_and_download, artist, title, rejected_source_urls)
