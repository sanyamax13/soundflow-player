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

from ._fsutil import artist_subdir, make_filename
from ._validators import duration_off, is_alternate_version

log = logging.getLogger(__name__)

# Планка битрейта. Была 224, снижена до 192 (yandex-music 3.0 для многих
# треков отдаёт только mp3 192, 320 — за отдельным sign-флоу, тут не
# реализовано), 24.09.2026 Alex ненадолго попросил вернуть 224, тут же сам
# передумал: «давай всё-таки 192 тогда сделаем и всё больше не меняем» —
# 192 ФИНАЛЬНОЕ решение, не трогать без нового явного «да» от Alex.
MIN_BITRATE = 192

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
    is_alternate: bool = False


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

    # Ремикс/лайв/кавер больше НЕ блокируется условием — правило Alex 23.09.2026
    # («не вместо оригинала, а вместе с оригиналом; убери условие "не нашло —
    # качает ремикс"»): один проход, альтернативная версия — обычный candidate.
    # Небольшой штраф к score (не жёсткий отказ) — чтобы при РАВНОМ совпадении
    # победил обычный вариант, а не порядок в выдаче Яндекса; если обычной нет
    # или ремикс заметно точнее совпадает — он и выигрывает как лучший.
    best, best_score, best_is_alt = None, 0.0, False
    for t in results[:12]:
        if not getattr(t, "available", True):
            continue
        ver = getattr(t, "version", None)
        full_title = f"{t.title} ({ver})" if ver else (t.title or "")
        is_alt = is_alternate_version(full_title, title)[0]
        t_artist = ", ".join(a.name for a in (t.artists or []) if a and a.name)
        # _sim2 — с учётом транслита: Яндекс часто пишет русских артистов
        # латиницей («Molchat Doma» ↔ «Молчат Дама»), побуквенное даёт 0.
        sa = max(_sim2(t_artist, artist), _sim2(_lead(t_artist), _lead(artist)))
        # Название: сравниваем и как есть, и без хвоста в скобках — у Яндекса
        # это часто подзаголовок («Судно (Борис Рыжий)» ↔ «Судно»).
        yt = t.title or ""
        st = max(_sim2(yt, title), _sim2(re.sub(r"\s*\([^)]*\)\s*$", "", yt), title))
        if sa < 0.5 or st < 0.55:
            continue
        score = sa * 0.4 + st * 0.6
        if is_alt:
            score *= 0.9
        if score > best_score:
            best_score, best, best_is_alt = score, t, is_alt
    if best is None:
        return None
    used_alt = best_is_alt
    if used_alt:
        ver = getattr(best, "version", None)
        log.info("yandex: взял альтернативную версию %r (%s)", best.title, ver or "?")

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
        bitrate_kbps=chosen_br, duration_sec=dur, score=best_score, is_alternate=used_alt,
    )


def _download_sync(artist: str, title: str, cache_dir, expected_duration_sec: int | None):
    found = _find_sync(artist, title, expected_duration_sec)
    if found is None:
        return None
    track, bitrate, match = found
    cache_dir = Path(cache_dir)
    out = artist_subdir(cache_dir, match.artist) / make_filename(match.artist, match.title)
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


# ───────── восстановлено 26.09.2026 ─────────
# Эти части жили только в рабочей копии качалки на brain (E:\soundflow-lab\fg-sidecar-src, вне git) и
# пропали вместе с ней 26.09.2026. Восстановлены по docs/DISCOVER-TAB.md, docs/YANDEX-PLAYLIST-LINK.md
# и по тому, что ждёт Go-клиент (apps/server/internal/sidecar/client.go). Теперь — в репозитории.

def _artists_of(obj) -> list[str]:
    return [a.name for a in (getattr(obj, "artists", None) or []) if a and getattr(a, "name", None)]


def _track_candidates_sync(artist: str, title: str, limit: int = 8):
    """Что Яндекс знает про трек: несколько найденных треков с исполнителями, названием и
    альбомами (с обложками). Решает «тот ли это трек» вызывающий (coverfind на Go)."""
    client = _get_client()
    if client is None:
        return []
    try:
        res = client.search(f"{artist} {title}", type_="track")
        results = (res.tracks.results if (res and res.tracks) else None) or []
    except Exception as e:  # noqa: BLE001
        log.warning("yandex track-candidates: поиск не вышел: %s", e)
        return []
    out = []
    for t in results[:limit]:
        albums = []
        for a in (getattr(t, "albums", None) or []):
            cu = getattr(a, "cover_uri", None)
            albums.append({
                "title": getattr(a, "title", "") or "",
                "artists": _artists_of(a),
                "compilation": (getattr(a, "type", "") == "compilation"),
                "cover_url": ("https://" + cu.replace("%%", "600x600")) if cu else "",
            })
        out.append({
            "artists": _artists_of(t),
            "title": getattr(t, "title", "") or "",
            "cover_url": _cover_url_of(t) or "",
            "albums": albums,
        })
    return out


async def track_candidates(artist: str, title: str):
    return await asyncio.to_thread(_track_candidates_sync, artist, title)


# ───────── послушать до скачивания (docs/DISCOVER-TAB.md, 19.09.2026) ─────────
def _stream_url_sync(track_id: str, artist: str, title: str):
    client = _get_client()
    if client is None:
        return None, None, "нет токена Яндекса"
    track = None
    if track_id:
        try:
            got = client.tracks([track_id])
            track = got[0] if got else None
        except Exception as e:  # noqa: BLE001
            log.warning("yandex stream-url: tracks([%s]) не вышло: %s", track_id, e)
    if track is None and artist and title:
        found = _find_sync(artist, title, None)
        if found is not None:
            track = found[0]
    if track is None:
        return None, None, "не нашла песню в Яндексе"
    try:
        infos = track.get_download_info()
    except Exception:  # noqa: BLE001
        return None, None, "Яндекс не отдал список файлов песни"
    mp3s = sorted((i for i in infos if i.codec == "mp3"), key=lambda i: i.bitrate_in_kbps or 0, reverse=True)
    for info in mp3s:
        try:
            return info.get_direct_link(), info.bitrate_in_kbps, None
        except Exception as e:  # noqa: BLE001
            log.warning("yandex stream-url: get_direct_link не вышло: %s", e)
    return None, None, "у Яндекса нет mp3 для этой песни"


async def stream_url(track_id: str, artist: str, title: str):
    return await asyncio.to_thread(_stream_url_sync, track_id, artist, title)


# ───────── плейлист по ссылке (docs/YANDEX-PLAYLIST-LINK.md, Alex TG 20117–20122) ─────────
_PL_HOST = re.compile(r"^(?:www\.)?music\.yandex\.(?:ru|com|by|kz|uz|ua)$", re.I)
_PL_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{5,79}$")
_PL_LOGIN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")

PL_BAD_LINK = ("Не похоже на ссылку на плейлист Яндекс.Музыки. Открой плейлист в Яндекс.Музыке, "
               "нажми «Поделиться» и скопируй ссылку.")


def parse_playlist_link(link: str):
    """Ссылка → ("uuid", "<lk.xxx>") | ("user", "<логин>", "<номер>") | None."""
    from urllib.parse import urlparse
    try:
        u = urlparse((link or "").strip())
        host = u.hostname or ""
    except ValueError:
        return None
    if u.scheme not in ("http", "https") or not _PL_HOST.match(host):
        return None
    parts = [p for p in u.path.split("/") if p]
    if len(parts) == 2 and parts[0] == "playlists" and _PL_ID.match(parts[1]):
        return ("uuid", parts[1])
    if len(parts) == 4 and parts[0] == "users" and parts[2] == "playlists" and parts[3].isdigit() \
            and _PL_LOGIN.match(parts[1]):
        return ("user", parts[1], parts[3])
    return None


def _raw_track_item(t):
    """Трек из «сырого» ответа API (словарь) → вид строки плейлиста; недоступные в стране пропускаем."""
    if not t or t.get("available") is False:
        return None
    tid = t.get("id") or t.get("realId")
    if not tid:
        return None
    artist = ", ".join(a.get("name", "") for a in (t.get("artists") or []) if a and a.get("name"))
    albs = t.get("albums") or []
    cover = t.get("coverUri") or (albs[0].get("coverUri") if albs else None)
    dur = t.get("durationMs")
    return {
        "yandex_id": str(tid),
        "artist": artist,
        "title": t.get("title") or "",
        "album": (albs[0].get("title") if albs else "") or "",
        "cover_url": ("https://" + cover.replace("%%", "600x600")) if cover else None,
        "duration_sec": (dur // 1000) if dur else None,
    }


def _obj_track_item(t):
    """То же для объекта библиотеки yandex_music."""
    if t is None or getattr(t, "available", True) is False:
        return None
    return {
        "yandex_id": str(t.id),
        "artist": ", ".join(a.name for a in (t.artists or []) if a and a.name),
        "title": t.title or "",
        "album": (t.albums[0].title if t.albums else "") or "",
        "cover_url": _cover_url_of(t),
        "duration_sec": (t.duration_ms // 1000) if t.duration_ms else None,
    }


def _playlist_sync(link: str):
    """→ (название, [треки], ошибка). Ошибка — по-русски, готова для показа Alex."""
    ref = parse_playlist_link(link)
    if ref is None:
        return "", [], PL_BAD_LINK
    client = _get_client()
    if client is None:  # токена нет — открытые плейлисты читаются и так
        try:
            from yandex_music import Client
            client = Client().init()
        except Exception as e:  # noqa: BLE001
            log.warning("yandex playlist: анонимный клиент не поднялся: %s", e)
            return "", [], "Яндекс сейчас не отвечает — попробуй чуть позже."
    try:
        if ref[0] == "uuid":
            raw = client._request.get(f"{client.base_url}/playlist/{ref[1]}")
            items = [it for it in (_raw_track_item(el.get("track")) for el in (raw.get("tracks") or [])) if it]
            return raw.get("title") or "Плейлист", items, None
        pls = client.users_playlists(int(ref[2]), user_id=ref[1])
        pl = pls[0] if isinstance(pls, list) else pls
        ids = [t.id for t in (pl.tracks or []) if getattr(t, "id", None)]
        full = client.tracks(ids) if ids else []
        items = [it for it in (_obj_track_item(t) for t in full) if it]
        return pl.title or "Плейлист", items, None
    except Exception as e:  # noqa: BLE001
        name = type(e).__name__
        log.warning("yandex playlist %s: %s %s", ref, name, e)
        if name in ("NotFoundError", "BadRequestError", "ForbiddenError"):
            return "", [], "Плейлист не открылся: ссылка устарела или плейлист закрыт (сделай его открытым и скопируй ссылку заново)."
        if name in ("NetworkError", "TimedOutError"):
            return "", [], "Яндекс не ответил — попробуй чуть позже."
        return "", [], "Не получилось открыть плейлист. Проверь ссылку."


async def playlist_by_link(link: str):
    return await asyncio.to_thread(_playlist_sync, link)


def _pairs(client, ids) -> list[dict]:
    """artist/title по id треков (пачками — Яндекс не любит тысячи id разом)."""
    out = []
    for i in range(0, len(ids), 200):
        for t in client.tracks(ids[i:i + 200]) or []:
            if t:
                out.append({"artist": ", ".join(_artists_of(t)), "title": t.title or ""})
    return out


# ───────── «Не рекомендовать» (чёрный список) ─────────
def _dislikes_sync():
    client = _get_client()
    if client is None:
        return [], "нет токена Яндекса"
    try:
        dl = client.users_dislikes_tracks()
        ids = [t.id for t in (dl.tracks if dl else []) or [] if getattr(t, "id", None)]
        return _pairs(client, ids), None
    except Exception as e:  # noqa: BLE001
        log.warning("yandex dislikes: %s", e)
        return [], "Яндекс не отдал «Не рекомендовать»"


async def dislikes():
    return await asyncio.to_thread(_dislikes_sync)


# ───────── начальный вкус своей копии плеера (28.09.2026) ─────────
# «Мне нравится» и песни из своих плейлистов человека — программа (cmd/soundflow/tasteseed.go) отмечает
# их лайками у тех песен, что уже есть в его каталоге. Только чтение, в аккаунт Яндекса ничего не пишется.
_SEED_MAX = 3000


def _taste_seed_sync():
    client = _get_client()
    if client is None:
        return [], "нет токена Яндекса"
    ids: list[str] = []
    seen: set[str] = set()

    def add(tid):
        tid = str(tid or "")
        if tid and tid not in seen and len(ids) < _SEED_MAX:
            seen.add(tid)
            ids.append(tid)

    try:
        likes = client.users_likes_tracks()
        for t in (likes.tracks if likes else []) or []:
            add(getattr(t, "id", None))
        for pl in client.users_playlists_list() or []:
            if len(ids) >= _SEED_MAX:
                break
            full = client.users_playlists(pl.kind, pl.owner.uid) if getattr(pl, "owner", None) else None
            for ts in (getattr(full, "tracks", None) or []):
                add(getattr(ts, "id", None) or getattr(getattr(ts, "track", None), "id", None))
        return _pairs(client, ids), None
    except Exception as e:  # noqa: BLE001
        log.warning("yandex taste seed: %s", e)
        return [], "Яндекс не отдал лайки и плейлисты"


async def taste_seed():
    return await asyncio.to_thread(_taste_seed_sync)


# ───────── сырые кандидаты «Волны» (cmd/soundflow/yandex_wave.go ранжирует сам) ─────────
# Источники: ещё треки у любимых артистов (топ по лайкам Яндекса + лайкнутые на телефоне), похожие
# артисты, популярное в тех же жанрах. НЕ личная рекомендация Яндекса и без записи в аккаунт Яндекса.
_WAVE_TOP_ARTISTS = 15
_WAVE_PER_ARTIST = 6
_WAVE_SIMILAR_PER_ARTIST = 2


def _wave_item(t, source: str, genre: str = ""):
    it = _obj_track_item(t)
    if not it:
        return None
    alb = t.albums[0] if getattr(t, "albums", None) else None
    it["genre"] = genre or (getattr(alb, "genre", "") or "")
    it["source"] = source
    it["album"] = it.get("album") or ""
    it["cover_url"] = it.get("cover_url") or ""
    it["duration_sec"] = it.get("duration_sec") or 0
    return it


def _wave_candidates_sync(extra_artists: list[str]):
    client = _get_client()
    if client is None:
        return [], "нет токена Яндекса"
    from collections import Counter
    liked_ids: set[str] = set()
    artist_count: Counter = Counter()
    artist_ids: dict[str, str] = {}
    genres: Counter = Counter()
    try:
        likes = client.users_likes_tracks()
        short = (likes.tracks if likes else []) or []
        ids = [s.id for s in short[:400] if getattr(s, "id", None)]
        full = client.tracks(ids) if ids else []
        for t in full:
            liked_ids.add(str(t.id))
            for a in (t.artists or []):
                if a and a.name:
                    artist_count[a.name] += 1
                    artist_ids.setdefault(a.name, str(a.id))
            alb = t.albums[0] if t.albums else None
            if alb is not None and getattr(alb, "genre", None):
                genres[alb.genre] += 1
    except Exception as e:  # noqa: BLE001
        log.warning("yandex wave: лайки не прочитались: %s", e)
    top = [name for name, _ in artist_count.most_common(_WAVE_TOP_ARTISTS)]
    for name in extra_artists or []:
        if name and name not in top:
            top.append(name)
    out, seen = [], set(liked_ids)

    def add(t, source, genre=""):
        tid = str(getattr(t, "id", ""))
        if not tid or tid in seen:
            return
        it = _wave_item(t, source, genre)
        if it:
            seen.add(tid)
            out.append(it)

    for name in top:
        aid = artist_ids.get(name)
        try:
            if not aid:
                res = client.search(name, type_="artist")
                best = res.artists.results[0] if (res and res.artists and res.artists.results) else None
                if best is None:
                    continue
                aid = str(best.id)
            tracks = client.artists_tracks(aid, page_size=_WAVE_PER_ARTIST)
            for t in (tracks.tracks if tracks else []) or []:
                add(t, "artist")
            info = client.artists_brief_info(aid)
            for sim in ((info.similar_artists if info else None) or [])[:_WAVE_SIMILAR_PER_ARTIST]:
                st = client.artists_tracks(sim.id, page_size=3)
                for t in (st.tracks if st else []) or []:
                    add(t, "similar_artist")
        except Exception as e:  # noqa: BLE001
            log.warning("yandex wave: артист %s: %s", name, e)
    for genre, _ in genres.most_common(3):
        try:
            res = client.search(genre, type_="track")
            for t in ((res.tracks.results if (res and res.tracks) else None) or [])[:10]:
                add(t, "genre", genre)
        except Exception as e:  # noqa: BLE001
            log.warning("yandex wave: жанр %s: %s", genre, e)
    return out, None


async def wave_candidates(extra_artists: list[str]):
    return await asyncio.to_thread(_wave_candidates_sync, extra_artists)


# ───────── жанр песни (26.09.2026, план Alex «по твоему плану», шаг 4) ─────────
# Хранитель жанров на сервере спрашивает сюда по каждой песне без жанра. Та же проверка
# «тот ли трек», что при скачивании (исполнитель ≥0.5, название ≥0.55 с учётом транслита),
# но без запроса ссылок на файл — только поиск. Жанр — у альбома трека (коды Яндекса:
# rusrap, pop, dance, rock, electronics, ruspop, alternative, metal, jazz, soundtrack…);
# сначала «свой» альбом, не сборник: у сборников жанр часто общий («pop»).
def _genre_sync(artist: str, title: str):
    client = _get_client()
    if client is None:
        return None, "нет токена Яндекса"
    try:
        res = client.search(f"{artist} {title}", type_="track")
        results = (res.tracks.results if (res and res.tracks) else None) or []
    except Exception as e:  # noqa: BLE001
        return None, f"поиск не вышел: {e}"
    best, best_score = None, 0.0
    for t in results[:10]:
        t_artist = ", ".join(a.name for a in (t.artists or []) if a and a.name)
        sa = max(_sim2(t_artist, artist), _sim2(_lead(t_artist), _lead(artist)))
        yt = t.title or ""
        st = max(_sim2(yt, title), _sim2(re.sub(r"\s*\([^)]*\)\s*$", "", yt), title))
        if sa < 0.5 or st < 0.55:
            continue
        score = sa * 0.4 + st * 0.6
        if score > best_score:
            best, best_score = t, score
    if best is None:
        return "", None  # искали, не нашли — это ответ, а не ошибка
    albums = list(getattr(best, "albums", None) or [])
    albums.sort(key=lambda a: 1 if getattr(a, "type", "") == "compilation" else 0)
    for a in albums:
        g = getattr(a, "genre", None)
        if g:
            return g, None
    return "", None


async def track_genre(artist: str, title: str):
    return await asyncio.to_thread(_genre_sync, artist, title)
