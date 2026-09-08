"""Yandex Music provider — поиск + скачивание в mp3 ≥224 (обычно 320) через
неофициальную либу yandex-music (MarshalX). Источник ВЫСОКОГО качества для
русского каталога: у Яндекса почти всё в 320, чего нет на бесплатных musify/трекерах.

Требует токен Плюс-аккаунта в env YANDEX_MUSIC_TOKEN (получен device-auth).
Подключён 11.06.2026 по решению Алекса (его личный Яндекс Плюс; это осознанный
override прежнего запрета «подписки не как источник аудио» в CLAUDE.md — для его
аккаунта). Токен НИКОГДА не логируем и не коммитим.
"""
from __future__ import annotations

import asyncio
import logging
import os
import re
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path

from ._validators import duration_off, is_alternate_version

log = logging.getLogger(__name__)

MIN_BITRATE = 224  # планка Алекса: ниже 224 не берём

_client = None
_client_failed = False


def _get_client():
    """Ленивая инициализация клиента (один раз). None если нет токена/ошибка."""
    global _client, _client_failed
    if _client is not None:
        return _client
    if _client_failed:
        return None
    token = os.environ.get("YANDEX_MUSIC_TOKEN", "").strip()
    if not token:
        _client_failed = True
        log.info("yandex: YANDEX_MUSIC_TOKEN не задан — провайдер выключен")
        return None
    try:
        from yandex_music import Client
        _client = Client(token).init()
        log.info("yandex: клиент инициализирован")
        return _client
    except Exception as e:  # noqa: BLE001
        _client_failed = True
        log.warning("yandex: init не удался: %s", e)
        return None


@dataclass
class YandexMatch:
    artist: str
    title: str
    track_id: str
    bitrate_kbps: int | None = None
    duration_sec: int | None = None
    score: float = 0.0


def _norm(s: str) -> str:
    return re.sub(r"[^a-zа-яё0-9]+", "", s.lower())


def _similarity(a: str, b: str) -> float:
    return SequenceMatcher(None, _norm(a), _norm(b)).ratio()


def _lead(artist: str) -> str:
    return re.split(r"\s*(?:feat\.?|ft\.?|&|,|\sx\s|\sх\s|vs\.?)\s*", artist, flags=re.I)[0].strip()


def _find_sync(artist: str, title: str, expected_duration_sec: int | None):
    client = _get_client()
    if client is None:
        return None
    try:
        res = client.search(f"{artist} {title}", type_="track")
        results = res.tracks.results if (res and res.tracks) else None
        if not results:
            res = client.search(title, type_="track")
            results = res.tracks.results if (res and res.tracks) else None
        if not results:
            return None
    except Exception as e:  # noqa: BLE001
        log.warning("yandex search failed %r—%r: %s", artist, title, e)
        return None

    best = None
    best_score = 0.0
    for t in results[:12]:
        if not getattr(t, "available", True):
            continue
        ver = getattr(t, "version", None)
        full_title = f"{t.title} ({ver})" if ver else (t.title or "")
        if is_alternate_version(full_title, title)[0]:
            continue
        t_artist = ", ".join(a.name for a in (t.artists or []) if a and a.name)
        sa = max(_similarity(t_artist, artist), _similarity(_lead(t_artist), _lead(artist)))
        st = _similarity(t.title or "", title)
        if sa < 0.5 or st < 0.55:
            continue
        score = sa * 0.4 + st * 0.6
        if score > best_score:
            best_score, best = score, t
    if best is None:
        return None

    dur = (best.duration_ms // 1000) if best.duration_ms else None
    if duration_off(dur, expected_duration_sec):
        log.info("yandex: skip wrong-duration %r (%ss vs %ss)", best.title, dur, expected_duration_sec)
        return None

    try:
        infos = best.get_download_info()
    except Exception as e:  # noqa: BLE001
        log.warning("yandex download_info failed: %s", e)
        return None
    mp3s = [i for i in infos if i.codec == "mp3" and (i.bitrate_in_kbps or 0) >= MIN_BITRATE]
    if not mp3s:
        return None
    mp3s.sort(key=lambda i: i.bitrate_in_kbps or 0, reverse=True)
    chosen_br = mp3s[0].bitrate_in_kbps
    t_artist = ", ".join(a.name for a in (best.artists or []) if a and a.name)
    return best, chosen_br, YandexMatch(
        artist=t_artist, title=best.title or title, track_id=str(best.id),
        bitrate_kbps=chosen_br, duration_sec=dur, score=best_score,
    )


def _download_sync(artist: str, title: str, cache_dir, expected_duration_sec: int | None):
    found = _find_sync(artist, title, expected_duration_sec)
    if found is None:
        return None
    track, bitrate, match = found
    cache_dir = Path(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    out = cache_dir / f"yandex-{match.track_id}.mp3"
    try:
        track.download(str(out), codec="mp3", bitrate_in_kbps=bitrate)
    except Exception as e:  # noqa: BLE001
        log.warning("yandex download failed %r—%r: %s", artist, title, e)
        return None
    try:
        if out.stat().st_size < 100_000:
            out.unlink()
            return None
    except OSError:
        return None
    return str(out), match


async def find_track(artist: str, title: str, expected_duration_sec: int | None = None) -> YandexMatch | None:
    found = await asyncio.to_thread(_find_sync, artist, title, expected_duration_sec)
    return found[2] if found else None


async def download_track(artist: str, title: str, cache_dir, expected_duration_sec: int | None = None):
    """search → download → save в cache_dir. Возвращает (file_path, YandexMatch) или None."""
    return await asyncio.to_thread(_download_sync, artist, title, cache_dir, expected_duration_sec)


# ───────────────────────── Обложка трека (дозакачка картинок) ─────────────────
# Для песен, у которых обложки нет НИ в одном источнике (cover_path/cover_url/
# artist_photo_url пустые) — в основном русские, которых iTunes/Deezer почти не
# знают. Возвращаем только URL картинки (avatars.yandex.net) — качает её и пишет
# cover_path уже сервер (apps/api/scripts/_fetch-track-covers-yandex.ts). Здесь
# НЕ требуем доступности/mp3: даже недоступный трек несёт верную обложку альбома.

# Яндекс часто пишет русских артистов латиницей (SERYABKINA, MACAN, ANNA ASTI),
# а в нашей БД они кириллицей («Ольга Серябкина») — побуквенное сравнение даёт ~0
# и верный трек отбраковывается. Поэтому в матчере обложки сравниваем имена,
# приведя обе стороны к латинице. Только для обложек: аудио-матчер не трогаем.
_RU2LAT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}


def _translit(s: str) -> str:
    return "".join(_RU2LAT.get(c, c) for c in s.lower())


def _norm_t(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", _translit(s))


def _sim2(a: str, b: str) -> float:
    """Схожесть с учётом транслита: max(прямое, по латинице)."""
    base = _similarity(a, b)
    ta, tb = _norm_t(a), _norm_t(b)
    if ta and tb:
        base = max(base, SequenceMatcher(None, ta, tb).ratio())
    return base


def _cover_url_of(t, size: str = "600x600") -> str | None:
    uri = getattr(t, "cover_uri", None)
    if not uri:
        albs = getattr(t, "albums", None)
        if albs:
            uri = getattr(albs[0], "cover_uri", None)
    if not uri:
        return None
    return "https://" + uri.replace("%%", size)


def _find_cover_sync(artist: str, title: str) -> str | None:
    client = _get_client()
    if client is None:
        return None
    try:
        res = client.search(f"{artist} {title}", type_="track")
        results = res.tracks.results if (res and res.tracks) else None
        if not results:
            res = client.search(title, type_="track")
            results = res.tracks.results if (res and res.tracks) else None
        if not results:
            return None
    except Exception as e:  # noqa: BLE001
        log.warning("yandex cover search failed %r—%r: %s", artist, title, e)
        return None

    best, best_score = None, 0.0
    for t in results[:12]:
        ver = getattr(t, "version", None)
        full_title = f"{t.title} ({ver})" if ver else (t.title or "")
        if is_alternate_version(full_title, title)[0]:
            continue
        t_artist = ", ".join(a.name for a in (t.artists or []) if a and a.name)
        sa = max(_sim2(t_artist, artist), _sim2(_lead(t_artist), _lead(artist)))
        st = _sim2(t.title or "", title)
        if sa < 0.5 or st < 0.55:
            continue
        score = sa * 0.4 + st * 0.6
        if score > best_score:
            best_score, best = score, t
    if best is None:
        return None
    return _cover_url_of(best)


async def find_track_cover(artist: str, title: str) -> str | None:
    """Поиск обложки трека на Яндексе по артист+название → URL картинки или None."""
    return await asyncio.to_thread(_find_cover_sync, artist, title)


# ───────────────────────── Поиск АРТИСТА (для онбординга) ─────────────────────
# Deezer (западный) плохо знает русских артистов и часто без фото. Яндекс знает
# их отлично + отдаёт фото и топ-треки. Используется в onboarding.resolveArtist
# (фото + кириллица) и onboarding-prefetch (топ-треки русских артистов).

def _search_artist_sync(name: str, with_tracks: bool = True):
    client = _get_client()
    if client is None:
        return None
    try:
        res = client.search(name, type_="artist")
        results = res.artists.results if (res and res.artists) else None
    except Exception as e:  # noqa: BLE001
        log.warning("yandex artist search failed %r: %s", name, e)
        return None
    if not results:
        return None
    # лучший по схожести имени (защита от тёзок/каверов)
    best, best_score = None, 0.0
    for a in results[:8]:
        an = a.name or ""
        s = max(_similarity(an, name), _similarity(_lead(an), _lead(name)))
        if s > best_score:
            best_score, best = s, a
    if best is None or best_score < 0.55:
        return None
    # фото: cover.uri (или og_image) с плейсхолдером размера %%
    cov = getattr(best, "cover", None)
    uri = getattr(cov, "uri", None) if cov else None
    if not uri:
        uri = getattr(best, "og_image", None)
    photo = ("https://" + uri.replace("%%", "400x400")) if uri else None
    top: list[dict] = []
    if with_tracks:
        try:
            bt = best.get_tracks(page=0, page_size=8)
            for t in (bt.tracks if bt else [])[:8]:
                if not t.title:
                    continue
                dur = (t.duration_ms // 1000) if getattr(t, "duration_ms", None) else None
                top.append({"title": t.title, "duration_sec": dur})
        except Exception as e:  # noqa: BLE001
            log.warning("yandex artist tracks failed %r: %s", name, e)
    return {
        "name": best.name or name,
        "photo_url": photo,
        "yandex_id": str(best.id),
        "top_tracks": top,
    }


async def search_artist(name: str, with_tracks: bool = True):
    """Поиск артиста на Яндексе → {name, photo_url, yandex_id, top_tracks} или None."""
    return await asyncio.to_thread(_search_artist_sync, name, with_tracks)
