"""Поиск и скачивание альбомов с rutor.info через qBittorrent (10.05.2026).

Зачем нужен. rutor.info — открытый трекер без регистрации. У rutracker
нестабильный Cloudflare 521 в РФ + нужен логин. rutor отдаёт страницу
за 0.5 сек анонимно. Ставим первым в chain — если найдём 320 mp3 альбом,
не лезем дальше.

Pipeline:
1. curl_cffi GET (impersonate chrome) /search/0/2/110/2/<query> — категория «Музыка», все слова
   из запроса в названии или описании, сортировка по сидам desc
2. Парсинг cp1251 HTML → список (title, .torrent URL, size, seeders)
3. Фильтр: title содержит «MP3», размер 30-300 МБ, сидеры > 0,
   артист встречается в названии
4. Для каждого кандидата: качаем .torrent с d.rutor.info → qBT paused →
   metadata уже есть в .torrent инлайн → проверка что нужный mp3
   внутри → если да — resume → ждём → сканируем папку
5. Возврат target_file_path + список всех mp3 (для bulk-индексации)

Почему .torrent file а НЕ magnet. Magnet требует DHT/пиров для bootstrap
metadata. На брайн-машине Mihomo на роутере режет UDP — DHT не работает,
все magnet'ы упирались в metadata timeout 60 сек. .torrent file несёт
metadata инлайн, не нужен DHT, работает сразу.

Переиспользует helpers из rutracker_album.py — `_qbt_client`,
`_simplify_artist`, `_wait_torrent_*`, `_torrent_has_target`,
`_read_album_tracks`, `_find_target_track`, `_download_lock`.
"""
from __future__ import annotations

import asyncio
import logging
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

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
from ._fsutil import _file_matches, normalize_key
from ._validators import is_compilation_title

log = logging.getLogger(__name__)

RUTOR_BASE = "https://rutor.info"
RUTOR_SEARCH_URL_TEMPLATE = (
    RUTOR_BASE + "/search/0/2/110/2/{query}"
)  # category=Music(2), method=all-words(1), in=name+desc(1), sort=seeders desc(2)
# rutor.info отдаёт UTF-8 (раньше был cp1251). cp1251 давал mojibake
# «Р»СѓС‡С€РёС…» в списке релизов (08.09.2026).
RUTOR_HTML_ENCODING = "utf-8"

MIN_ALBUM_SIZE = 30 * 1024 * 1024
MAX_ALBUM_SIZE = 300 * 1024 * 1024

CFFI_GET_RETRY = 6  # curl_cffi иногда флапает 'invalid library' (известный баг) — ретраим

# Регексы: одна строка результата. <tr class="gai"> и <tr class="tum">
# чередуются (зебра). Внутри — ссылка на .torrent (//d.rutor.info/download/<ID>),
# magnet, ссылка на топик с title, размер, сиды/личи.
_RE_ROW = re.compile(r'<tr class="(?:gai|tum)">.*?</tr>', re.S)
_RE_TORRENT_URL = re.compile(r'<a class="downgif" href="(//d\.rutor\.info/download/\d+)"')
_RE_TOPIC_TITLE = re.compile(r'<a href="/torrent/(\d+)[^"]*">([^<]+)</a>')
_RE_SIZE = re.compile(r'(\d+(?:\.\d+)?)&nbsp;(KB|MB|GB)', re.I)
_RE_SEEDERS = re.compile(
    r'<span class="green"><img[^>]+/>&nbsp;(\d+)</span>'
)
_RE_LEECHERS = re.compile(r'<span class="red">&nbsp;(\d+)</span>')


@dataclass
class RutorDownloadResult:
    target_file_path: str
    album_dir: str
    target_meta: AlbumTrack
    forum_url: str  # rutor URL раздачи (/torrent/<ID>/...)
    all_tracks: list[AlbumTrack] = field(default_factory=list)


def _cffi_get(url: str, *, timeout: float = 8.0):
    """GET через curl_cffi с impersonate=chrome. rutor режет обычный TLS-отпечаток
    питона (отдаёт 0/без ответа), а под видом Chrome — нормальный 200 (как с
    SoundCloud). Retry на флапающей ошибке curl_cffi 'invalid library'/TLS."""
    last_exc: Exception | None = None
    for attempt in range(CFFI_GET_RETRY):
        try:
            return cffi_requests.get(
                url,
                impersonate="chrome",
                headers={"Accept-Language": "ru-RU,ru;q=0.9"},
                timeout=timeout,
            )
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
            msg = str(exc).lower()
            transient = any(
                s in msg
                for s in (
                    "invalid library", "tls connect", "unexpected_eof",
                    "curl: (35)", "curl: (56)", "curl: (92)",
                )
            )
            if transient and attempt < CFFI_GET_RETRY - 1:
                time.sleep(1 + attempt)
                continue
            log.warning("rutor curl_cffi GET failed (%s): %s", url, exc)
            return None
    log.warning("rutor curl_cffi GET: исчерпаны попытки (%s): %s", url, last_exc)
    return None


def _http_get_search(query: str) -> str | None:
    """Один запрос к rutor /search. Возвращает HTML (cp1251 → str) или None.

    Слеш в имени артиста (AC/DC) ломает rutor — URL `/AC%2FDC` отдаёт
    0 результатов. Заменяем `/` на пробел перед URL-encode."""
    from urllib.parse import quote

    sanitized = query.replace("/", " ").strip()
    url = RUTOR_SEARCH_URL_TEMPLATE.format(query=quote(sanitized, safe=""))
    r = _cffi_get(url)
    if r is None:
        return None
    if r.status_code != 200:
        log.warning("rutor search HTTP %d for %r", r.status_code, query)
        return None
    try:
        return r.content.decode(RUTOR_HTML_ENCODING, errors="replace")
    except Exception as exc:
        log.warning("rutor html decode failed: %s", exc)
        return None


def _size_to_bytes(value: float, unit: str) -> int:
    unit_upper = unit.upper()
    if unit_upper == "KB":
        return int(value * 1024)
    if unit_upper == "MB":
        return int(value * 1024 * 1024)
    if unit_upper == "GB":
        return int(value * 1024 * 1024 * 1024)
    return 0


def _parse_results(html: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for row in _RE_ROW.findall(html):
        m_torrent = _RE_TORRENT_URL.search(row)
        m_title = _RE_TOPIC_TITLE.search(row)
        m_size = _RE_SIZE.search(row)
        m_seeds = _RE_SEEDERS.search(row)
        m_leech = _RE_LEECHERS.search(row)
        if not (m_torrent and m_title and m_size):
            continue
        try:
            size_bytes = _size_to_bytes(float(m_size.group(1)), m_size.group(2))
        except ValueError:
            continue
        # //d.rutor.info/download/123 → https://d.rutor.info/download/123
        torrent_url = "https:" + m_torrent.group(1)
        out.append(
            {
                "title": m_title.group(2).strip(),
                "topic_id": m_title.group(1),
                "topic_url": f"{RUTOR_BASE}/torrent/{m_title.group(1)}",
                "torrent_url": torrent_url,
                "size_bytes": size_bytes,
                "seeders": int(m_seeds.group(1)) if m_seeds else 0,
                "leechers": int(m_leech.group(1)) if m_leech else 0,
            }
        )
    return out


def _download_torrent_bytes(torrent_url: str) -> bytes | None:
    """Скачивает .torrent file с d.rutor.info. Возвращает bytes или None."""
    r = _cffi_get(torrent_url)
    if r is None:
        return None
    if r.status_code != 200:
        log.warning("rutor .torrent HTTP %d for %s", r.status_code, torrent_url)
        return None
    ctype = r.headers.get("content-type", "").lower()
    if "torrent" not in ctype and not r.content.startswith(b"d"):
        log.warning("rutor .torrent: not a torrent file (ctype=%s)", ctype)
        return None
    return r.content


def _do_search(artist: str) -> list[dict[str, Any]]:
    """Поиск на rutor по имени артиста. Узкий запрос artist+title пробовали —
    выдаёт VA-сборники (которые не дают студийный звук), толку нет. Лучше
    тащить альбомы артиста целиком и потом искать нужный mp3 внутри.

    Стратегии: полное имя → упрощённое (до запятой/амперсанда) для коллабов.
    """
    queries: list[str] = [artist]
    simplified = _simplify_artist(artist)
    if simplified != artist:
        queries.append(simplified)
    for q in queries:
        html = _http_get_search(q)
        if html is None:
            continue
        results = _parse_results(html)
        if results:
            if q != artist:
                log.info("rutor_album: упрощённый запрос %r дал %d", q, len(results))
            return results
    return []


def _filter_candidates(
    results: list[dict[str, Any]], artist_key: str
) -> list[dict[str, Any]]:
    """MP3 + размер 30-300 МБ + сидеры > 0 + артист в названии."""
    out = []
    for r in results:
        title = str(r.get("title", ""))
        size = int(r.get("size_bytes") or 0)
        seeders = int(r.get("seeders") or 0)
        if "MP3" not in title.upper():
            continue
        if size < MIN_ALBUM_SIZE or size > MAX_ALBUM_SIZE:
            continue
        if seeders < 1:
            continue
        # артист встречается в названии (передаём artist дважды,
        # _file_matches требует и artist и title — обходной приём)
        if not _file_matches(title, artist_key, artist_key):
            continue
        # Сборник (топ лета / хиты / VA) — не качаем целиком как «альбом артиста».
        if is_compilation_title(title):
            log.info("rutor_album: пропускаю сборник (не альбом артиста): %r", title)
            continue
        out.append(r)
    out.sort(key=lambda r: int(r.get("seeders") or 0), reverse=True)
    return out


def _add_torrent_paused(qbt: qbittorrentapi.Client, torrent_bytes: bytes) -> None:
    """Добавляет .torrent file в qBT в paused-режиме."""
    try:
        qbt.torrent_categories.create_category(
            name=QBT_CATEGORY, save_path=str(config.albums_dir)
        )
    except Exception:
        pass
    qbt.torrents.add(
        torrent_files=[torrent_bytes],
        save_path=str(config.albums_dir),
        category=QBT_CATEGORY,
        is_paused=True,
        use_auto_tmm=False,
    )


def _do_find_and_download(
    artist: str,
    title: str,
    rejected_source_urls: set[str] | None = None,
) -> RutorDownloadResult | None:
    rejected = rejected_source_urls or set()
    if not config.qbt_user or not config.qbt_pass:
        log.error("rutor_album: QBT_USER/QBT_PASS не настроены")
        return None
    artist_key = normalize_key(artist)
    title_key = normalize_key(title)

    log.info("rutor_album: search by artist=%r (target track=%r)", artist, title)
    results = _do_search(artist)
    if not results:
        log.info("rutor_album: 0 search results")
        return None
    candidates = _filter_candidates(results, artist_key)
    log.info(
        "rutor_album: %d/%d отфильтрованных кандидатов (MP3 + size + seeders)",
        len(candidates), len(results),
    )
    if not candidates:
        return None

    qbt = _qbt_client()
    qbt.auth_log_in()
    config.albums_dir.mkdir(parents=True, exist_ok=True)

    for cand in candidates[:MAX_CANDIDATES_TO_TRY]:
        # Skip ранее отклонённые источники (см. rejected_track_files в БД)
        if cand["topic_url"] in rejected:
            log.info(
                "rutor_album: rejected-source skip: %s — %s source_url=%s",
                artist, title, cand["topic_url"],
            )
            continue
        log.info(
            "rutor_album: try %s (%d MB, %d seeders)",
            cand["title"],
            cand["size_bytes"] // (1024 * 1024),
            cand["seeders"],
        )
        torrent_bytes = _download_torrent_bytes(cand["torrent_url"])
        if not torrent_bytes:
            continue
        before = {t.hash for t in qbt.torrents.info(category=QBT_CATEGORY)}
        try:
            _add_torrent_paused(qbt, torrent_bytes)
        except qbittorrentapi.Conflict409Error:
            log.info("rutor_album: torrent уже есть в qBittorrent, скип")
            continue
        except Exception as exc:
            log.warning("rutor_album: qbt.add failed: %s", exc)
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
            log.warning("rutor_album: не нашёл новый торрент в qBittorrent")
            continue

        files = _wait_torrent_metadata(qbt, new_hash)
        if files is None:
            log.warning("rutor_album: metadata не получены, удаляю torrent %s", new_hash)
            try:
                qbt.torrents.delete(torrent_hashes=new_hash, delete_files=True)
            except Exception:
                pass
            continue
        if not _torrent_has_target(files, title_key):
            log.info(
                "rutor_album: в torrent нет mp3 с именем '%s' (всего %d файлов), удаляю",
                title, len(files),
            )
            try:
                qbt.torrents.delete(torrent_hashes=new_hash, delete_files=True)
            except Exception:
                pass
            continue
        log.info("rutor_album: в torrent есть подходящий mp3, начинаю полную скачку")

        try:
            qbt.torrents.start(torrent_hashes=new_hash)
        except Exception as exc:
            log.warning("rutor_album: не смог resume torrent %s: %s", new_hash, exc)
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
        log.info("rutor_album: в альбоме %d mp3 (папка %s)", len(all_tracks), album_dir)
        target = _find_target_track(all_tracks, artist_key, title_key)
        if target is None:
            log.info(
                "rutor_album: целевой трек %r не найден в альбоме, пробуем следующий кандидат",
                title,
            )
            continue

        log.info("rutor_album: нашли %s в альбоме", target.file_path)
        return RutorDownloadResult(
            target_file_path=target.file_path,
            album_dir=str(album_dir),
            target_meta=target,
            forum_url=cand["topic_url"],
            all_tracks=all_tracks,
        )

    log.info("rutor_album: ни один из %d кандидатов не дал нужный трек", len(candidates))
    return None


async def find_and_download(
    artist: str,
    title: str,
    *,
    rejected_source_urls: set[str] | None = None,
) -> RutorDownloadResult | None:
    async with _download_lock:
        return await asyncio.to_thread(_do_find_and_download, artist, title, rejected_source_urls)
