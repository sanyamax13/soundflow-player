"""Режим 2 «Торренты — обзор»: поиск по АРТИСТУ на трекерах со списком
релизов (без скачивания), потом скачивание выбранного через qBittorrent.

Alex сам смотрит список (альбом, год, формат, битрейт, размер, сиды) и
ставит галочки — ничего не качается «скрытно».

Опирается на уже существующие адаптеры nnmclub_album / rutor_album /
tapochek_album / rustorka_album: у каждого есть `_do_search(artist)` (даёт
сырой список) и `_download_torrent_bytes(...)`. qBT-ожидание и чтение
альбома — общие helpers из rutracker_album.
"""
from __future__ import annotations

import asyncio
import logging
import re
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

ALL_TRACKERS = ("nnmclub", "rutor", "tapochek", "rustorka")

_YEAR = re.compile(r"(?:19|20)\d{2}")
_FMT = re.compile(r"\b(FLAC|APE|WavPack|WV|ALAC|Lossless|MP3|AAC|OGG|M4A)\b", re.I)
_BR = re.compile(r"\b(V0|V2|320|256|224|192|160|128)\b")


def _meta_from_title(title: str) -> dict[str, Any]:
    years = _YEAR.findall(title)
    year = int(years[0]) if years else None
    mf = _FMT.search(title)
    fmt = mf.group(1).upper() if mf else None
    if fmt in ("APE", "WV", "WAVPACK", "ALAC", "LOSSLESS"):
        fmt = "FLAC" if fmt == "LOSSLESS" else fmt.lower()
    mb = _BR.search(title)
    br = None
    if mb:
        v = mb.group(1).upper()
        br = {"V0": 245, "V2": 190}.get(v)
        if br is None and v.isdigit():
            br = int(v)
    # альбом = название до первой скобки/года, без формата
    alb = re.split(r"\s*[\(\[]", title, 1)[0].strip(" -–—")
    return {"album": alb or None, "year": year, "fmt": fmt, "bitrate_kbps": br}


def _norm(*, tracker: str, title: str, size_bytes: int, seeders: int,
          leechers: int, forum_url: str, dl_ref: str) -> dict:
    import html as _h
    title = _h.unescape((title or "").strip())
    m = _meta_from_title(title)
    return {
        "tracker": tracker,
        "forum_url": forum_url or "",
        "dl_ref": dl_ref or "",
        "magnet": None,
        "title": title,
        "album": m["album"],
        "year": m["year"],
        "fmt": m["fmt"],
        "bitrate_kbps": m["bitrate_kbps"],
        "size_bytes": int(size_bytes or 0),
        "seeders": int(seeders or 0),
        "leechers": int(leechers or 0),
    }


def _words_in(needle: str, haystack: str) -> bool:
    hk = re.sub(r"[^\wа-яё ]+", " ", haystack.lower(), flags=re.I)
    return all(w in hk for w in re.sub(r"[^\wа-яё ]+", " ", needle.lower(), flags=re.I).split() if len(w) >= 2)


def _keep(c: dict, artist: str, album: str | None) -> bool:
    if c["seeders"] < 1:
        return False
    try:
        from ._validators import is_compilation_title
        if is_compilation_title(c["title"]):
            return False
    except Exception:
        pass
    # артист должен реально встречаться в названии релиза (rutor ищет широко и
    # отдаёт «Алла Пугачева» на запрос «Молчат Дома»)
    if not _words_in(artist, c["title"]):
        return False
    if album and not _words_in(album, c["title"]):
        return False
    # музыкальные релизы на этих трекерах почти всегда несут формат в
    # названии (MP3 320 / FLAC). Игры и фильмы — нет. Отсекаем не-музыку.
    if not c["fmt"]:
        return False
    return True


# ─────────────────────────── поиск (без скачивания) ───────────────────────────


def _search_rutor(artist: str) -> list[dict]:
    from . import rutor_album as m
    return [
        _norm(tracker="rutor", title=r.get("title", ""), size_bytes=r.get("size_bytes", 0),
              seeders=r.get("seeders", 0), leechers=r.get("leechers", 0),
              forum_url=r.get("topic_url", ""), dl_ref=r.get("torrent_url", ""))
        for r in m._do_search(artist)
    ]


def _search_nnmclub(artist: str) -> list[dict]:
    from . import nnmclub_album as m
    s = m._ensure_session()
    if s is None:
        raise RuntimeError("нет входа (кука NNMCLUB_COOKIE)")
    return [
        _norm(tracker="nnmclub", title=r.get("title", ""), size_bytes=r.get("size_bytes", 0),
              seeders=r.get("seeders", 0), leechers=r.get("leechers", 0),
              forum_url=r.get("topic_url", ""), dl_ref=str(r.get("download_id", "")))
        for r in m._do_search(s, artist)
    ]


def _search_tapochek(artist: str) -> list[dict]:
    from . import tapochek_album as m
    from ..config import config as cfg
    if m._ensure_session(cfg.tapochek_user, cfg.tapochek_pass) is None:
        raise RuntimeError("не залогинился (TAPOCHEK_USER/PASS)")
    return [
        _norm(tracker="tapochek", title=r.get("fileName", ""), size_bytes=r.get("fileSize", 0),
              seeders=r.get("nbSeeders", 0), leechers=r.get("nbLeechers", 0),
              forum_url=r.get("descrLink", ""), dl_ref=r.get("fileUrl", ""))
        for r in m._do_search(artist)
    ]


def _search_rustorka(artist: str) -> list[dict]:
    from . import rustorka_album as m
    if not m.available():
        raise RuntimeError("нет входа (RUSTORKA_COOKIE)")
    return [
        _norm(tracker="rustorka", title=r.get("title", ""), size_bytes=r.get("size_bytes", 0),
              seeders=r.get("seeders", 0), leechers=r.get("leechers", 0),
              forum_url=r.get("topic_url", ""), dl_ref=r.get("torrent_url", ""))
        for r in m._do_search(artist)
    ]


_SEARCHERS = {
    "rutor": _search_rutor,
    "nnmclub": _search_nnmclub,
    "tapochek": _search_tapochek,
    "rustorka": _search_rustorka,
}


async def search_all(
    artist: str, album: str | None, trackers: set[str],
) -> tuple[list[dict], list[str]]:
    want = [t for t in ALL_TRACKERS if not trackers or t in trackers]
    log.info("torrent_browse: поиск %r альбом=%r трекеры=%s", artist, album, want)

    async def one(t: str):
        try:
            return t, await asyncio.to_thread(_SEARCHERS[t], artist), None
        except Exception as e:  # noqa: BLE001
            log.warning("torrent_browse: %s упал: %s", t, e)
            return t, [], f"{t}: {e}"

    results = await asyncio.gather(*(one(t) for t in want))
    cands: list[dict] = []
    errs: list[str] = []
    for _t, lst, err in results:
        if err:
            errs.append(err)
        for c in lst:
            if _keep(c, artist, album):
                cands.append(c)
    # дубли по (album, year, fmt) — оставляем с большим числом сидов
    best: dict[tuple, dict] = {}
    for c in cands:
        k = ((c["album"] or c["title"]).lower(), c["year"], c["fmt"])
        if k not in best or c["seeders"] > best[k]["seeders"]:
            best[k] = c
    out = sorted(best.values(), key=lambda c: c["seeders"], reverse=True)
    return out[:40], errs


# ─────────────────────── скачивание выбранного релиза ───────────────────────


def _torrent_bytes(tracker: str, dl_ref: str) -> bytes | None:
    if tracker == "rutor":
        from . import rutor_album as m
        return m._download_torrent_bytes(dl_ref)
    if tracker == "nnmclub":
        from . import nnmclub_album as m
        s = m._ensure_session()
        return m._download_torrent_bytes(s, dl_ref) if s else None
    if tracker == "tapochek":
        from . import tapochek_album as m
        return m._download_torrent_file(dl_ref)
    if tracker == "rustorka":
        from . import rustorka_album as m
        return m._download_torrent_bytes(dl_ref)
    return None


def _do_download(tracker: str, forum_url: str, dl_ref: str) -> dict | None:
    from .rutracker_album import (
        _qbt_client, _read_album_tracks, _wait_torrent_complete, _wait_torrent_metadata,
        QBT_CATEGORY,
    )
    from ..config import config
    import qbittorrentapi  # type: ignore

    tb = _torrent_bytes(tracker, dl_ref)
    if not tb:
        log.warning("torrent_browse: не скачал .torrent (%s %s)", tracker, dl_ref)
        return None

    qbt = _qbt_client()
    qbt.auth_log_in()
    config.albums_dir.mkdir(parents=True, exist_ok=True)
    try:
        qbt.torrent_categories.create_category(name=QBT_CATEGORY, save_path=str(config.albums_dir))
    except Exception:
        pass

    before = {t.hash for t in qbt.torrents.info(category=QBT_CATEGORY)}
    try:
        qbt.torrents.add(torrent_files=[tb], save_path=str(config.albums_dir),
                         category=QBT_CATEGORY, is_paused=False)
    except qbittorrentapi.Conflict409Error:
        pass
    except Exception as exc:
        log.warning("torrent_browse: qbt.add: %s", exc)
        return None

    new_hash = None
    for _ in range(20):
        import time
        time.sleep(1)
        for t in qbt.torrents.info(category=QBT_CATEGORY):
            if t.hash not in before:
                new_hash = t.hash
                break
        if new_hash:
            break
    if not new_hash:
        log.warning("torrent_browse: новый торрент в qBittorrent не появился")
        return None

    if _wait_torrent_metadata(qbt, new_hash) is None:
        _safe_del(qbt, new_hash)
        return None
    try:
        qbt.torrents.start(torrent_hashes=new_hash)
    except Exception:
        pass
    info = _wait_torrent_complete(qbt, new_hash)
    if info is None:
        _safe_del(qbt, new_hash)
        return None
    try:
        qbt.torrents.stop(torrent_hashes=new_hash)
    except Exception:
        pass

    cp = info.get("content_path") or info.get("save_path")
    album_dir = Path(cp) if cp else config.albums_dir
    if album_dir.is_file():
        album_dir = album_dir.parent
    tracks = _read_album_tracks(album_dir)
    log.info("torrent_browse: %s — %d mp3 в %s", tracker, len(tracks), album_dir)
    return {
        "album_dir": str(album_dir),
        "tracks": [
            {
                "file_path": t.file_path, "artist": t.artist, "title": t.title,
                "album": t.album, "duration_sec": t.duration_sec,
                "bitrate_kbps": t.bitrate_kbps, "size_bytes": t.size_bytes,
            }
            for t in tracks
        ],
    }


def _safe_del(qbt, h):
    try:
        qbt.torrents.delete(torrent_hashes=h, delete_files=True)
    except Exception:
        pass


_dl_lock = asyncio.Lock()


async def download_pick(
    tracker: str, forum_url: str, dl_ref: str, want_title: str | None,
) -> dict | None:
    async with _dl_lock:
        return await asyncio.to_thread(_do_download, tracker, forum_url, dl_ref or forum_url)
