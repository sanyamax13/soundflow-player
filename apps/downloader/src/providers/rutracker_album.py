"""Поиск и скачивание альбомов с rutracker.org через qBittorrent.

Используется как fallback после SoundCloud в audio_chain. SoundCloud отдаёт
треки в 128 kbps и иногда превью; здесь мы качаем альбомы целиком в 320 kbps
mp3 — попутно индексируем все mp3 из альбома в track_files (расширяет базу
для будущего алгоритма «Твой Вайб»).

Pipeline:
1. qBittorrent search через rutracker plugin → результаты (50-300 МБ MP3 альбомы)
2. Login в rutracker через httpx → скачать .torrent файл байтами
3. qBittorrent: add_torrent с категорией soundflow-prefetch
4. Polling до completion, с timeout
5. Pause торрент (не сидируем, см. project_mihomo_constraint.md)
6. Сканируем папку альбома через mutagen → ищем трек где title совпадает с искомым
7. Возвращаем путь к нужному mp3 + список всех mp3 (для bulk-индексации)

Поиск идёт ПО АРТИСТУ, не по «artist + title» — на rutracker одиночные
треки лежат внутри альбомов, а поиск ищет совпадение в названии форум-темы.
"""
from __future__ import annotations

import asyncio
import logging
import re
import time
from urllib.parse import quote
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import qbittorrentapi  # type: ignore[import-untyped]
from curl_cffi import requests as cffi_requests

from ..config import config
from ._validators import is_compilation_title, is_quality_title, validate_audio_file, validate_full_track
from ._fsutil import _file_matches, normalize_key

log = logging.getLogger(__name__)

QBT_CATEGORY = "soundflow-prefetch"
DOWNLOAD_TIMEOUT_SEC = 240  # hard cap. Малосидируемые альбомы качаются медленно — было 120, не хватало
METADATA_TIMEOUT_SEC = 60  # время на получение metadata (имена файлов в торренте)
POLL_INTERVAL_SEC = 3
# Early-abort на мёртвый торрент. Два окна:
#  - рой ПУСТ (num_complete==0) → мёртвый, отсекаем за DEAD_GRACE (30с), чтобы
#    живой плеер-chain не висел на zombie-раздачах (rutor: 1 офлайн-сидер).
#  - сидеры в рое ЕСТЬ, но мы ещё не подключились → даём CONNECT_GRACE (90с):
#    у малосидируемых раздач (1-5 пиров за NAT) коннект через VPN занимает 40-60с.
TORRENT_DEAD_GRACE_SEC = 30
TORRENT_CONNECT_GRACE_SEC = 90
TORRENT_DEAD_MIN_BYTES = 100 * 1024  # 100 KB — должно скачаться за grace
TORRENT_DEAD_MIN_SPEED_BPS = 1024  # 1 KB/s — иначе peer есть но не отдаёт
MIN_ALBUM_SIZE = 30 * 1024 * 1024
MAX_ALBUM_SIZE = 300 * 1024 * 1024
MAX_CANDIDATES_TO_TRY = 5
RUTRACKER_BASE = "https://rutracker.org"
RUTRACKER_LOGIN_URL = f"{RUTRACKER_BASE}/forum/login.php"
RUTRACKER_SEARCH_URL = f"{RUTRACKER_BASE}/forum/tracker.php"
RUTRACKER_DOWNLOAD_URL = f"{RUTRACKER_BASE}/forum/dl.php"
RUTRACKER_TOPIC_URL = f"{RUTRACKER_BASE}/forum/viewtopic.php"

# Regex для парсинга HTML страницы поиска — взяты из плагина nbusseneau/rutracker.py
_RE_THREADS = re.compile(r'<tr id="trs-tr-\d+".*?</tr>', re.S)
_RE_TORRENT = re.compile(
    r'a data-topic_id="(?P<id>\d+?)".*?>(?P<title>.+?)<'
    r".+?"
    r'data-ts_text="(?P<size>\d+?)"'
    r".+?"
    r'data-ts_text="(?P<seeds>[-\d]+?)"'
    r".+?"
    r"leechmed.+?>(?P<leech>\d+?)<",
    re.S,
)
RUTRACKER_HTML_ENCODING = "windows-1251"

# Сессия rutracker — глобальная, чтобы не логиниться на каждый трек
_rutracker_client: "cffi_requests.Session | None" = None
_rutracker_login_lock = asyncio.Lock()
# Один альбом за раз — Mihomo на роутере давится от параллельных торрентов
_download_lock = asyncio.Lock()


@dataclass
class AlbumTrack:
    file_path: str
    artist: str
    title: str
    album: str | None
    track_no: int | None
    duration_sec: int | None
    bitrate_kbps: int | None
    size_bytes: int


@dataclass
class RutrackerDownloadResult:
    target_file_path: str  # путь к найденному совпадающему mp3
    album_dir: str
    target_meta: AlbumTrack
    forum_url: str  # rutracker URL раздачи (descrLink)
    all_tracks: list[AlbumTrack] = field(default_factory=list)


def _load_rutracker_creds() -> tuple[str, str]:
    """Логин/пароль rutracker: сперва из .env (RUTRACKER_USER/PASS), иначе из
    плагина qBittorrent (куда вписали при установке)."""
    if config.rutracker_user and config.rutracker_pass:
        return config.rutracker_user, config.rutracker_pass
    plugin_path = Path.home() / "AppData/Local/qBittorrent/nova3/engines/rutracker.py"
    if plugin_path.exists():
        text = plugin_path.read_text(encoding="utf-8")
        m_u = re.search(r'username\s*=\s*"([^"]+)"', text)
        m_p = re.search(r'password\s*=\s*"([^"]+)"', text)
        if m_u and m_p:
            return m_u.group(1), m_p.group(1)
    return "", ""


def _ensure_rutracker_session() -> "cffi_requests.Session | None":
    """Сессия rutracker через curl_cffi (impersonate chrome — обычный TLS-отпечаток
    rutracker режет, как SoundCloud).

    Вход на rutracker требует капчу (программой не решаемую), поэтому приоритет —
    «пропуск» из браузера: config.rutracker_cookie вида "bb_session=...; bb_data=...".
    Если cookie задан — ходим по нему без логина. Иначе fallback на логин паролем
    (упрётся в капчу — оставлен на случай если её снимут)."""
    global _rutracker_client
    if _rutracker_client is not None:
        return _rutracker_client
    session = cffi_requests.Session(impersonate="chrome")

    cookie = (config.rutracker_cookie or "").strip()
    if cookie:
        for part in cookie.split(";"):
            name, sep, val = part.strip().partition("=")
            if sep and name:
                session.cookies.set(name.strip(), val.strip(), domain=".rutracker.org")
        _rutracker_client = session
        log.info(
            "rutracker: cookie-сессия (без логина), куки: %s",
            [c.name for c in session.cookies.jar],
        )
        return session

    user, password = _load_rutracker_creds()
    if not user or not password or user == "YOUR_USERNAME_HERE":
        log.error("rutracker: ни cookie, ни логин/пароль не настроены")
        return None
    # rutracker — windows-1251; login=Вход в cp1251 url-encoded
    data = "&".join(
        [f"login_username={user}", f"login_password={password}", "login=%C2%F5%EE%E4"]
    )
    try:
        r = session.post(
            RUTRACKER_LOGIN_URL,
            data=data.encode("ascii"),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=30,
        )
    except Exception as exc:
        log.error("rutracker login failed: %s", exc)
        return None
    if not (session.cookies.get("bb_session") or session.cookies.get("bb_data")):
        log.error(
            "rutracker login: cookie не получен (status=%d) — вероятно капча; нужен RUTRACKER_COOKIE",
            r.status_code,
        )
        return None
    log.info("rutracker login OK")
    _rutracker_client = session
    return session


def _download_torrent_file(torrent_url: str) -> bytes | None:
    """Скачивает .torrent файл с rutracker (нужны куки от login).

    Cloudflare у rutracker иногда отдаёт 521/522 (origin не отвечает) — делаем
    retry с экспоненциальной задержкой.
    """
    client = _rutracker_client
    if client is None:
        log.error("rutracker session not initialized")
        return None
    delays = [0, 1, 2, 3, 4]  # 5 попыток — у rutracker бывает шторм Cloudflare 521
    for i, delay in enumerate(delays):
        if delay:
            time.sleep(delay)
        try:
            r = client.get(torrent_url, timeout=10.0)
        except Exception as exc:
            log.warning("rutracker .torrent attempt %d failed: %s", i + 1, exc)
            continue
        if r.status_code == 200:
            ctype = r.headers.get("content-type", "").lower()
            if "torrent" not in ctype and not r.content.startswith(b"d"):
                log.error("rutracker .torrent: not a torrent file (ctype=%s)", ctype)
                return None
            return r.content
        if r.status_code in (521, 522, 524, 502, 503):
            log.warning(
                "rutracker .torrent attempt %d: Cloudflare HTTP %d, retry...",
                i + 1, r.status_code,
            )
            continue
        log.error("rutracker .torrent: HTTP %d for %s", r.status_code, torrent_url)
        return None
    log.error("rutracker .torrent: все %d попыток не удались для %s", len(delays), torrent_url)
    return None


def _qbt_client() -> qbittorrentapi.Client:
    return qbittorrentapi.Client(
        host=f"http://{config.qbt_host}:{config.qbt_port}",
        username=config.qbt_user,
        password=config.qbt_pass,
        REQUESTS_ARGS={"timeout": (10, 30)},
    )


def _simplify_artist(artist: str) -> str:
    """Упрощение составного имени артиста для поиска.

    rutracker ищет по точному совпадению слов в названии раздачи. Запросы
    типа «Aarne, Toxi$ & Big Baby Tape» практически никогда не находят
    альбом — берём первого артиста до первого разделителя.
    """
    # Разделители: запятая, амперсанд, "feat.", "ft.", "x" (collab)
    separators = [",", "&", " feat.", " feat ", " ft.", " ft ", " x ", " X "]
    s = artist.strip()
    for sep in separators:
        idx = s.lower().find(sep.lower())
        if idx > 0:
            s = s[:idx].strip()
    return s or artist


def _cp1251_search_url(base: str, query: str) -> str:
    """tapochek и rutracker — сайты в windows-1251. Параметр nm надо слать в
    cp1251 url-encode; httpx по умолчанию кодирует utf-8 и кириллица не находится
    (Latin-запросы не страдают, но русские артисты давали 0 результатов)."""
    return f"{base}?nm={quote(query.encode('windows-1251', 'replace'))}"


def _http_get_search(query: str) -> str | None:
    """Запрос к tracker.php с retry: у rutracker Cloudflare нестабилен (521 шторм),
    а curl_cffi изредка флапает 'invalid library' — ретраим оба случая."""
    client = _rutracker_client
    if client is None:
        return None
    url = _cp1251_search_url(RUTRACKER_SEARCH_URL, query)
    for attempt in range(6):
        try:
            r = client.get(url, timeout=10.0)
        except Exception as exc:
            log.warning("rutracker search attempt %d failed: %s", attempt + 1, exc)
            time.sleep(0.4)
            continue
        if r.status_code == 200:
            try:
                return r.content.decode(RUTRACKER_HTML_ENCODING, errors="replace")
            except Exception as exc:
                log.error("rutracker html decode failed: %s", exc)
                return None
        if r.status_code in (521, 522, 524, 502, 503):
            log.warning("rutracker search attempt %d: Cloudflare %d, retry", attempt + 1, r.status_code)
            time.sleep(0.4)
            continue
        log.error("rutracker search HTTP %d", r.status_code)
        return None
    log.error("rutracker search: исчерпаны попытки (Cloudflare 521 шторм)")
    return None


def _parse_search_html(html: str) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for thread_html in _RE_THREADS.findall(html):
        m = _RE_TORRENT.search(thread_html)
        if not m:
            continue
        d = m.groupdict()
        try:
            tid = d["id"]
            results.append(
                {
                    "fileName": _strip_html(d["title"]),
                    "fileSize": int(d["size"]),
                    "nbSeeders": max(0, int(d["seeds"])),
                    "nbLeechers": int(d["leech"]),
                    "fileUrl": f"{RUTRACKER_DOWNLOAD_URL}?t={tid}",
                    "descrLink": f"{RUTRACKER_TOPIC_URL}?t={tid}",
                }
            )
        except (KeyError, ValueError) as exc:
            log.debug("skip torrent: %s", exc)
    return results


def _do_search(artist: str) -> list[dict[str, Any]]:
    """Поиск на rutracker через нашу curl_cffi-сессию.

    Стратегия:
    1. Пробуем полное имя артиста как есть
    2. Если 0 — пробуем упрощённое (до первого разделителя): «Aarne, Toxi$ & Big Baby Tape» → «Aarne»
    3. Если HTML без результатов и без login-страницы — re-login (возможно session expired) и retry

    Обычный TLS-отпечаток rutracker режет (521/без ответа), поэтому curl_cffi с
    impersonate=chrome — как для SoundCloud.
    """
    if _rutracker_client is None:
        log.error("rutracker_album: session not initialized в _do_search")
        return []

    queries = [artist]
    simplified = _simplify_artist(artist)
    if simplified != artist:
        queries.append(simplified)

    for q in queries:
        html = _http_get_search(q)
        if html is None:
            continue
        # Если HTML это login page — сессия expired, перелогинимся и retry
        if 'name="login_username"' in html and "tracker.php" not in html:
            log.warning("rutracker session expired, перелогин")
            _force_relogin()
            html = _http_get_search(q)
            if html is None:
                continue
        results = _parse_search_html(html)
        if results:
            if q != artist:
                log.info("rutracker_album: упрощённый запрос %r дал %d", q, len(results))
            return results
    return []


def _force_relogin() -> None:
    """Сбросить сессию и пересоздать (cookie или логин паролем)."""
    global _rutracker_client
    _rutracker_client = None
    _ensure_rutracker_session()


def _strip_html(s: str) -> str:
    """Убирает HTML-теги и декодирует HTML-entities."""
    import html as _html

    s = re.sub(r"<[^>]+>", "", s)
    return _html.unescape(s).strip()


def _filter_candidates(
    results: list[dict[str, Any]], artist_key: str
) -> list[dict[str, Any]]:
    """Фильтр результатов rutracker — только MP3 альбомы среднего размера, с
    сидерами, и где артист действительно встречается в названии."""
    out = []
    for r in results:
        name_upper = str(r.get("fileName", "")).upper()
        size = int(r.get("fileSize") or 0)
        seeders = int(r.get("nbSeeders") or 0)
        if "MP3" not in name_upper:
            continue
        if size < MIN_ALBUM_SIZE or size > MAX_ALBUM_SIZE:
            continue
        if seeders < 1:
            continue
        # Артист должен встречаться (в латинице или кириллице)
        if not _file_matches(str(r.get("fileName", "")), artist_key, artist_key):
            # _file_matches требует и artist и title; передаём artist дважды,
            # значит достаточно артиста в названии
            continue
        # Сборник (топ лета / хиты / VA) — не качаем целиком как «альбом артиста».
        if is_compilation_title(str(r.get("fileName", ""))):
            log.info("rutracker_album: пропускаю сборник (не альбом артиста): %r", r.get("fileName"))
            continue
        out.append(r)
    out.sort(key=lambda r: int(r.get("nbSeeders") or 0), reverse=True)
    return out


def _wait_torrent_complete(qbt: qbittorrentapi.Client, info_hash: str) -> dict[str, Any] | None:
    """Polling до тех пор пока торрент не скачается. Возвращает torrent info.

    Early-abort: если за TORRENT_DEAD_GRACE_SEC секунд (30 сек) торрент не
    нашёл активных пиров и не скачал минимум 100 КБ — считаем мёртвым и
    возвращаем None (caller удалит). Без этого 1-сидерные «зомби» торренты
    с rutor блокировали chain на полный DOWNLOAD_TIMEOUT_SEC.
    """
    start_time = time.time()
    deadline = start_time + DOWNLOAD_TIMEOUT_SEC
    while time.time() < deadline:
        torrents = qbt.torrents.info(torrent_hashes=info_hash)
        if not torrents:
            log.warning("torrent %s исчез из qBittorrent", info_hash)
            return None
        t = torrents[0]
        state = t.get("state")
        progress = t.get("progress", 0)
        if progress >= 1.0 or state in ("uploading", "stalledUP", "queuedUP", "pausedUP", "forcedUP"):
            return dict(t)
        if state in ("error", "missingFiles", "unknown"):
            log.warning("torrent %s в ошибочном состоянии %s", info_hash, state)
            return None

        # Early-abort на dead torrent
        elapsed = time.time() - start_time
        if elapsed >= TORRENT_DEAD_GRACE_SEC:
            num_seeds = int(t.get("num_seeds") or 0)  # подключённые сидеры
            swarm_seeds = int(t.get("num_complete") or 0)  # сидеры в рое (трекер; -1 = ещё не известно)
            downloaded = int(t.get("downloaded") or 0)
            dlspeed = int(t.get("dlspeed") or 0)
            no_progress = (
                num_seeds == 0
                and downloaded < TORRENT_DEAD_MIN_BYTES
                and dlspeed < TORRENT_DEAD_MIN_SPEED_BPS
            )
            # Рой пуст (num_complete==0) → мёртвый сразу. Сидеры есть (или ещё
            # неизвестно), но не подключились за CONNECT_GRACE → недостижимы, abort.
            if no_progress and (swarm_seeds == 0 or elapsed >= TORRENT_CONNECT_GRACE_SEC):
                log.warning(
                    "torrent %s — мёртвый (swarm=%d, 0 conn, %d bytes, %d bps за %ds), abort",
                    info_hash, swarm_seeds, downloaded, dlspeed, int(elapsed),
                )
                return None

        log.debug(
            "torrent %s state=%s progress=%.2f seeds=%s dlspeed=%s",
            info_hash, state, progress, t.get("num_seeds"), t.get("dlspeed"),
        )
        time.sleep(POLL_INTERVAL_SEC)
    log.warning("torrent %s timeout по %d сек", info_hash, DOWNLOAD_TIMEOUT_SEC)
    return None


def _wait_torrent_metadata(qbt: qbittorrentapi.Client, info_hash: str) -> list[dict[str, Any]] | None:
    """Ждёт пока qBittorrent скачает metadata торрента (имена файлов).

    Возвращает список файлов: [{name, size, ...}] или None при timeout/ошибке.
    Содержимое файлов НЕ скачивается (торрент остаётся paused и/или с приоритетом 0).
    """
    deadline = time.time() + METADATA_TIMEOUT_SEC
    while time.time() < deadline:
        try:
            files = qbt.torrents.files(torrent_hash=info_hash)
        except qbittorrentapi.NotFound404Error:
            time.sleep(1)
            continue
        if files:
            # Имеем хотя бы один файл — metadata получены
            return [dict(f) for f in files]
        time.sleep(2)
    log.warning("torrent %s metadata timeout по %d сек", info_hash, METADATA_TIMEOUT_SEC)
    return None


def _torrent_has_target(files: list[dict[str, Any]], title_key: str) -> bool:
    """Проверяет есть ли в торренте mp3-файл с именем содержащим искомое название.

    Защита от live-альбомов: проверяем is_quality_title по ПОЛНОМУ relative path
    внутри торрента («AC/DC - Live At River Plate (2011) MP3/04. Highway To Hell.mp3»)
    — слово «live» часто только в названии папки альбома, а имя самого mp3
    «04. Highway To Hell.mp3» выглядит как студийная версия. qBT в metadata
    отдаёт torrent-relative path (без user save_path), false-positive на
    локальные пути исключён.
    """
    for f in files:
        rel_path = str(f.get("name", "")).replace("\\", "/")
        if not rel_path.lower().endswith(".mp3"):
            continue
        leaf = rel_path.rsplit("/", 1)[-1]
        if title_key not in normalize_key(leaf):
            continue
        ok, reason = is_quality_title(rel_path)
        if not ok:
            log.debug("torrent_has_target: skip %s (%s)", rel_path, reason)
            continue
        return True
    return False


def _read_album_tracks(album_dir: Path) -> list[AlbumTrack]:
    """Рекурсивно сканирует папку, читает теги mp3 через mutagen.

    Невалидные mp3 (битый header, обрезанные, < 100 KB) пропускаются и
    удаляются — не должны попадать в track_files.
    """
    out: list[AlbumTrack] = []
    if not album_dir.exists():
        return out
    for p in album_dir.rglob("*.mp3"):
        # Сразу отсекаем мусор: 30+ MB альбом часто содержит .mp3 заглушки
        # на 5-50 KB или html-странички с нулевыми тегами
        if not validate_audio_file(p, source="rutracker_album"):
            continue
        # Skits/intro в альбомах часто < 90с. Не ставим их в track_files —
        # пусть остаются на диске для альбомного контекста, но из vibe-pool
        # выпадают.
        if not validate_full_track(p, source="rutracker_album"):
            continue
        try:
            from mutagen import File as MutagenFile  # type: ignore
            from mutagen.easyid3 import EasyID3  # type: ignore

            try:
                tags = EasyID3(str(p))
            except Exception:
                tags = None
            mfile = MutagenFile(str(p))
            artist = ""
            title = ""
            album = None
            track_no: int | None = None
            if tags is not None:
                artist = (tags.get("artist") or [""])[0]
                title = (tags.get("title") or [""])[0]
                album = (tags.get("album") or [None])[0]
                track_str = (tags.get("tracknumber") or [""])[0]
                m = re.match(r"^(\d+)", track_str)
                if m:
                    track_no = int(m.group(1))
            duration_sec = None
            bitrate_kbps = None
            if mfile is not None and mfile.info is not None:
                dur = getattr(mfile.info, "length", None)
                if dur:
                    duration_sec = int(dur)
                br = getattr(mfile.info, "bitrate", None)
                if br:
                    bitrate_kbps = int(br) // 1000
            # Fallback — если в тегах нет artist/title, парсим имя файла
            if not artist or not title:
                stem = p.stem
                if " - " in stem:
                    parts = stem.split(" - ", 1)
                    if not artist:
                        artist = parts[0].strip()
                    if not title:
                        title = parts[1].strip()
                else:
                    if not title:
                        title = stem
            out.append(
                AlbumTrack(
                    file_path=str(p),
                    artist=artist,
                    title=title,
                    album=album,
                    track_no=track_no,
                    duration_sec=duration_sec,
                    bitrate_kbps=bitrate_kbps,
                    size_bytes=p.stat().st_size,
                )
            )
        except Exception as exc:
            log.warning("mutagen read failed for %s: %s", p, exc)
    return out


def _find_target_track(
    tracks: list[AlbumTrack], artist_key: str, title_key: str
) -> AlbumTrack | None:
    """Ищет mp3 с подходящим title в уже скачанной папке альбома.

    Дубль-защита от live: если в title тега есть «(Live)» — пропускаем,
    даже если title_key совпадает. _torrent_has_target проверяет до скачки,
    но если альбом уже скачан и в нём есть и live и студийная версии,
    предпочесть студийную.
    """
    for t in tracks:
        title_n = normalize_key(t.title)
        if not (title_key in title_n or title_n in title_key):
            continue
        ok, _ = is_quality_title(t.title)
        if not ok:
            continue
        return t
    return None


def _do_find_and_download(
    artist: str,
    title: str,
    rejected_source_urls: set[str] | None = None,
) -> RutrackerDownloadResult | None:
    rejected = rejected_source_urls or set()
    if not config.qbt_user or not config.qbt_pass:
        log.error("rutracker_album: QBT_USER/QBT_PASS не настроены")
        return None
    artist_key = normalize_key(artist)
    title_key = normalize_key(title)

    # Сессия rutracker — cookie из браузера (вход требует капчу) или логин паролем.
    if _ensure_rutracker_session() is None:
        return None

    log.info("rutracker_album: search by artist=%r (target track=%r)", artist, title)
    results = _do_search(artist)
    if not results:
        log.info("rutracker_album: 0 search results")
        return None
    candidates = _filter_candidates(results, artist_key)
    log.info(
        "rutracker_album: %d/%d отфильтрованных кандидатов (mp3 + size + seeders)",
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
                "rutracker_album: rejected-source skip: %s — %s source_url=%s",
                artist, title, descr_link,
            )
            continue
        log.info(
            "rutracker_album: try %s (%d MB, %d seeders)",
            cand.get("fileName"),
            int(cand.get("fileSize") or 0) // (1024 * 1024),
            int(cand.get("nbSeeders") or 0),
        )
        torrent_bytes = _download_torrent_file(torrent_url)
        if not torrent_bytes:
            continue

        # Узнать какие торренты УЖЕ есть в нашей категории — чтобы найти новый
        before = {t.hash for t in qbt.torrents.info(category=QBT_CATEGORY)}
        try:
            qbt.torrent_categories.create_category(name=QBT_CATEGORY, save_path=str(config.albums_dir))
        except Exception:
            pass
        # Шаг 1: добавляем торрент paused — qBittorrent скачает только metadata
        # (имена файлов), но не сами файлы. Если в этом торренте нет mp3 с
        # подходящим именем — удаляем без скачивания, экономим время и место.
        # qbittorrent-api принимает bytes напрямую; tuple (name, bytes) даёт
        # TorrentFileNotFoundError.
        try:
            qbt.torrents.add(
                torrent_files=[torrent_bytes],
                save_path=str(config.albums_dir),
                category=QBT_CATEGORY,
                is_paused=True,
            )
        except qbittorrentapi.Conflict409Error:
            # Торрент уже добавлен в qBittorrent (прошлый прогон). Скипаем —
            # значит мы этот альбом уже проверяли и/или скачали; повторно
            # тратить время не нужно.
            log.info("rutracker_album: torrent уже есть в qBittorrent, скип")
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
            log.warning("rutracker_album: не нашёл новый торрент в qBittorrent")
            continue

        # Шаг 2: ждём metadata, проверяем имена файлов
        files = _wait_torrent_metadata(qbt, new_hash)
        if files is None:
            log.warning("rutracker_album: metadata не получены, удаляю torrent %s", new_hash)
            try:
                qbt.torrents.delete(torrent_hashes=new_hash, delete_files=True)
            except Exception:
                pass
            continue
        if not _torrent_has_target(files, title_key):
            log.info(
                "rutracker_album: в torrent нет mp3 с именем '%s' (всего %d файлов), удаляю",
                title, len(files),
            )
            try:
                qbt.torrents.delete(torrent_hashes=new_hash, delete_files=True)
            except Exception:
                pass
            continue
        log.info("rutracker_album: в torrent есть подходящий mp3, начинаю полную скачку")

        # Шаг 3: запускаем скачивание (resume) и ждём завершения
        try:
            qbt.torrents.start(torrent_hashes=new_hash)
        except Exception as exc:
            log.warning("rutracker_album: не смог resume torrent %s: %s", new_hash, exc)
            continue

        info = _wait_torrent_complete(qbt, new_hash)
        if info is None:
            # Удаляем неудачный торрент с файлами
            try:
                qbt.torrents.delete(torrent_hashes=new_hash, delete_files=True)
            except Exception:
                pass
            continue

        # Pause — не раздаём
        try:
            qbt.torrents.stop(torrent_hashes=new_hash)
        except Exception:
            pass

        # content_path — папка/файл созданный торрентом
        content_path = info.get("content_path") or info.get("save_path")
        album_dir = Path(content_path) if content_path else config.albums_dir
        if album_dir.is_file():
            album_dir = album_dir.parent

        all_tracks = _read_album_tracks(album_dir)
        log.info("rutracker_album: в альбоме %d mp3 (папка %s)", len(all_tracks), album_dir)
        target = _find_target_track(all_tracks, artist_key, title_key)
        if target is None:
            log.info(
                "rutracker_album: целевой трек %r не найден в альбоме, пробуем следующий кандидат",
                title,
            )
            # НЕ удаляем — альбом останется в БД для будущего вайба, просто переходим
            # (Можно потом отфильтровывать дубли по info_hash)
            continue

        log.info("rutracker_album: нашли %s в альбоме", target.file_path)
        return RutrackerDownloadResult(
            target_file_path=target.file_path,
            album_dir=str(album_dir),
            target_meta=target,
            forum_url=str(cand.get("descrLink") or ""),
            all_tracks=all_tracks,
        )

    log.info("rutracker_album: ни один из %d кандидатов не дал нужный трек", len(candidates))
    return None


async def find_and_download(
    artist: str,
    title: str,
    *,
    rejected_source_urls: set[str] | None = None,
) -> RutrackerDownloadResult | None:
    async with _download_lock:
        return await asyncio.to_thread(_do_find_and_download, artist, title, rejected_source_urls)
