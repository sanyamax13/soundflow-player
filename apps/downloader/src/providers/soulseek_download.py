"""Поиск и скачивание трека через Soulseek (slskd).

Используется prefetch-charts скриптом и в будущем on-demand для треков
которых нет в локальном кеше.
"""
from __future__ import annotations

import asyncio
import logging
import re
import shutil
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
from slskd_api import SlskdClient  # type: ignore[import-untyped]

from ..config import config
from ._validators import (
    validate_audio_file,
    validate_full_track,
    validate_id3_match,
    validate_quality_metadata,
)

log = logging.getLogger(__name__)

# Soulseek peer-передача может быть медленной, особенно из России.
# Если за DOWNLOAD_TIMEOUT_SEC файл не докачался — переходим к следующему юзеру.
SEARCH_MIN_WAIT_SEC = 6.0   # минимум — slskd иногда рапортует isComplete до того как responses готовы
SEARCH_TIMEOUT_SEC = 20.0    # для русского контента / редких треков peers медленно отвечают
SEARCH_MIN_RESPONSES = 3     # break когда накопилось хотя бы 3 юзера с файлами
DOWNLOAD_TIMEOUT_SEC = 90.0
POLL_INTERVAL_SEC = 2.0

AUDIO_EXTENSIONS = (".mp3",)  # FLAC и прочее пока пропускаем для простоты MVP

# Запрещённые символы в именах файлов на Windows
_FORBIDDEN_FS_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


@dataclass
class DownloadResult:
    file_path: str
    bitrate_kbps: int | None
    duration_sec: int | None
    size_bytes: int
    source: str  # 'soulseek'
    soulseek_user: str  # для логов
    soulseek_filename: str  # оригинальное имя


def normalize_key(s: str) -> str:
    """Нормализация для дедупликации: lowercase, без диакритики, только буквы и цифры.

    Кириллица оставляется как есть (не транслитерируем — это меняет смысл).
    """
    s = s.lower().strip()
    # Убираем диакритику от латиницы (é → e), кириллицу не трогаем
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    # Оставляем буквы (latin + cyrillic) и цифры, остальное в пробел
    s = re.sub(r"[^\wЀ-ӿ]+", " ", s, flags=re.UNICODE)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def make_filename(artist: str, title: str, ext: str = ".mp3") -> str:
    """Генерация имени файла «Artist - Title.mp3» с заменой запрещённых символов."""
    artist_clean = _FORBIDDEN_FS_CHARS.sub("_", artist).strip()
    title_clean = _FORBIDDEN_FS_CHARS.sub("_", title).strip()
    return f"{artist_clean} - {title_clean}{ext}"


def _file_matches(filename: str, artist_key: str, title_key: str) -> bool:
    """Проверка что имя файла реально содержит artist + title.

    Раньше проверяли через substring (`artist in norm and title in norm`),
    но это пропускало случаи где порядок слов отличается. Пример:
      title_key: "кукла feat vonamour remix 2026"
      norm:      "кукла remix 2026 feat vonamour"
    substring не совпадает, хотя все слова есть.

    Сейчас: каждое значимое слово (>=2 символов) из artist_key И title_key
    должно встретиться в norm — порядок не важен. Игнорируем короткие шумовые
    слова которые в названии могут быть пропущены без потери смысла.
    """
    norm = normalize_key(filename)

    def all_words_present(key: str) -> bool:
        words = [w for w in key.split() if len(w) >= 2]
        if not words:
            return True
        return all(w in norm for w in words)

    return all_words_present(artist_key) and all_words_present(title_key)


def _search_sync(query: str) -> list[dict[str, Any]]:
    """Возвращает список response-объектов от slskd с files."""
    try:
        client = SlskdClient(host=config.slskd_url, api_key=config.slskd_api_key)
        started = client.searches.search_text(query)
        search_id = started["id"]
    except Exception as exc:
        log.warning("soulseek search init failed: %s", exc)
        return []

    # На isComplete полагаться нельзя — slskd говорит True до того как responses
    # реально доступны через /responses. Ориентируемся на responseCount —
    # реальное число юзеров с файлами.
    elapsed = 0.0
    while elapsed < SEARCH_TIMEOUT_SEC:
        time.sleep(POLL_INTERVAL_SEC)
        elapsed += POLL_INTERVAL_SEC
        if elapsed < SEARCH_MIN_WAIT_SEC:
            continue
        try:
            state = client.searches.state(search_id)
        except Exception as exc:
            log.warning("soulseek search poll failed: %s", exc)
            break
        # responseCount — реальное число пиров с файлами (не isComplete)
        if state.get("responseCount", 0) >= SEARCH_MIN_RESPONSES:
            break
        # Если slskd говорит isComplete=True но 0 ответов — ждём ещё, peers
        # могут передать поздно. Только если elapsed ≥ MIN_WAIT * 2 и
        # isComplete=True — выходим, чтобы не висеть впустую
        if state.get("isComplete") and elapsed >= SEARCH_MIN_WAIT_SEC * 2:
            break

    # slskd_api 0.2 не передаёт includeFiles=true → responses возвращаются
    # без `files` и без `username`. Делаем прямой HTTP запрос.
    try:
        url = f"{config.slskd_url.rstrip('/')}/api/v0/searches/{search_id}/responses?includeFiles=true"
        r = httpx.get(
            url,
            headers={"X-API-Key": config.slskd_api_key},
            timeout=10.0,
        )
        r.raise_for_status()
        return r.json() or []
    except Exception as exc:
        log.warning("soulseek search responses failed: %s", exc)
        return []


def _select_candidates(
    responses: list[dict[str, Any]],
    artist: str,
    title: str,
    min_bitrate: int,
    max_candidates: int,
) -> list[dict[str, Any]]:
    """Из всех response-файлов выбираем подходящие mp3 ≥ min_bitrate.

    Возвращает список {username, filename, size, bitRate} отсортированный
    по битрейту убыванию (лучшее качество первое).
    """
    artist_key = normalize_key(artist)
    title_key = normalize_key(title)
    candidates: list[dict[str, Any]] = []
    for resp in responses:
        username = str(resp.get("username") or "")
        if not username:
            continue
        for f in resp.get("files") or []:
            fname = str(f.get("filename") or "")
            if not fname.lower().endswith(AUDIO_EXTENSIONS):
                continue
            br = f.get("bitRate")
            if not isinstance(br, int) or br < min_bitrate:
                continue
            if not _file_matches(fname, artist_key, title_key):
                continue
            size = f.get("size") or 0
            candidates.append({
                "username": username,
                "filename": fname,
                "size": int(size),
                "bitRate": br,
            })
    candidates.sort(key=lambda c: -c["bitRate"])
    return candidates[:max_candidates]


def _enqueue_and_wait(
    client: SlskdClient,
    username: str,
    filename: str,
    size: int,
) -> tuple[bool, str | None]:
    """Ставит в очередь и ждёт завершения. Возвращает (success, error_message)."""
    try:
        client.transfers.enqueue(username=username, files=[{"filename": filename, "size": size}])
    except Exception as exc:
        return False, f"enqueue failed: {exc}"

    elapsed = 0.0
    while elapsed < DOWNLOAD_TIMEOUT_SEC:
        try:
            user_transfer = client.transfers.get_downloads(username=username) or {}
        except Exception as exc:
            return False, f"poll failed: {exc}"

        # get_downloads возвращает один user-объект {username, directories: [...]}
        target = None
        for dir_ in user_transfer.get("directories") or []:
            for f in dir_.get("files") or []:
                if f.get("filename") == filename:
                    target = f
                    break
            if target:
                break

        if target:
            state = str(target.get("state") or "")
            if "Completed, Succeeded" in state:
                return True, None
            if "Errored" in state or "Cancelled" in state or "TimedOut" in state:
                return False, f"state: {state}"

        time.sleep(POLL_INTERVAL_SEC)
        elapsed += POLL_INTERVAL_SEC

    return False, f"timeout after {DOWNLOAD_TIMEOUT_SEC:.0f}s"


def _find_downloaded_file(slskd_filename: str) -> Path | None:
    """slskd кладёт файлы в подпапку <username>/path/file.mp3.

    Ищем по basename во всём дереве downloads_dir.
    """
    base = Path(slskd_filename).name
    for p in config.slskd_downloads_dir.rglob(base):
        if p.is_file():
            return p
    return None


def _extract_metadata(path: Path) -> tuple[int | None, int | None]:
    """Возвращает (bitrate_kbps, duration_sec) из mp3 через mutagen."""
    try:
        from mutagen.mp3 import MP3  # type: ignore[import-untyped]
        audio = MP3(str(path))
        bitrate = int(audio.info.bitrate / 1000) if audio.info.bitrate else None
        duration = int(audio.info.length) if audio.info.length else None
        return bitrate, duration
    except Exception as exc:
        log.warning("mutagen failed for %s: %s", path, exc)
        return None, None


def _move_to_cache(src: Path, artist: str, title: str) -> Path:
    """Перемещает файл из slskd-downloads в track_cache_dir с нормализованным именем."""
    config.track_cache_dir.mkdir(parents=True, exist_ok=True)
    dst = config.track_cache_dir / make_filename(artist, title, src.suffix)
    # Если файл с таким именем уже есть — добавляем суффикс (1), (2), ...
    counter = 1
    while dst.exists():
        stem = make_filename(artist, title, "")[:-1]  # без точки расширения
        dst = config.track_cache_dir / f"{stem} ({counter}){src.suffix}"
        counter += 1
    shutil.move(str(src), str(dst))
    return dst


# Soulseek по NDA с лейблами блокирует поиск с этими словами в query.
# Workaround — split-search: дробим artist на отдельные слова, пробуем
# по одному. Файлы в сети есть, но прямой запрос с полным именем
# возвращает 0 results.
_SOULSEEK_BLOCKED_PHRASES = (
    "beatles", "michael jackson", "lady gaga", "metallica",
    "prince",  # известно что Prince's estate тоже блокирует
)


def _is_blocked_artist(artist: str) -> bool:
    a = artist.lower()
    return any(b in a for b in _SOULSEEK_BLOCKED_PHRASES)


def _query_variants(artist: str, title: str) -> list[str]:
    """Возвращает 1+ вариантов поискового запроса. Для забаненных артистов
    пробуем сначала full, потом split-варианты (последнее слово артиста +
    title), потом только title."""
    variants = [f"{artist} {title}"]
    if _is_blocked_artist(artist):
        words = artist.split()
        if len(words) >= 2:
            # «John Lennon» → пробуем «Lennon Hey Jude» (фамилия + title)
            variants.append(f"{words[-1]} {title}")
        # Только title — последний шанс, может быть много мусора но
        # _select_candidates всё равно отфильтрует по match
        variants.append(title)
    return variants


def _do_find_and_download(
    artist: str,
    title: str,
    min_bitrate_kbps: int,
    max_candidates: int,
    rejected_source_urls: set[str] | None = None,
) -> DownloadResult | None:
    rejected = rejected_source_urls or set()
    """Синхронная реализация. Запускается в asyncio.to_thread."""
    candidates: list[dict] = []
    used_query = ""
    for variant in _query_variants(artist, title):
        log.info("soulseek: try query %r", variant)
        responses = _search_sync(variant)
        if not responses:
            log.info("soulseek: 0 responses for %r", variant)
            continue
        cands = _select_candidates(
            responses, artist, title, min_bitrate_kbps, max_candidates,
        )
        if cands:
            candidates = cands
            used_query = variant
            break
        log.info("soulseek: 0 candidates ≥%d kbps for %r", min_bitrate_kbps, variant)

    if not candidates:
        return None
    log.info("soulseek: используем query %r (%d candidates)", used_query, len(candidates))

    client = SlskdClient(host=config.slskd_url, api_key=config.slskd_api_key)
    last_error: str | None = None
    for cand in candidates:
        username = cand["username"]
        filename = cand["filename"]
        size = cand["size"]
        bitrate = cand["bitRate"]
        # source_url для Soulseek = slsk://<peer>/<filename> — уникальный
        # fingerprint конкретного файла на peer'е.
        source_url = f"slsk://{username}/{filename}"
        if source_url in rejected:
            log.info(
                "soulseek: rejected-source skip: %s — %s source_url=%s",
                artist, title, source_url,
            )
            continue
        log.info(
            "soulseek: trying %s/%s (%d kbps, %d bytes)",
            username, Path(filename).name, bitrate, size,
        )

        success, err = _enqueue_and_wait(client, username, filename, size)
        if not success:
            log.info("soulseek: failed: %s", err)
            last_error = err
            continue

        # Файл скачан, ищем его в downloads
        downloaded = _find_downloaded_file(filename)
        if not downloaded:
            log.warning("soulseek: file vanished after success: %s", filename)
            last_error = "file vanished after success"
            continue

        # Перемещаем в кеш с красивым именем
        dst = _move_to_cache(downloaded, artist, title)

        # Общая валидация (размер + magic bytes). Soulseek peer мог отдать
        # битый/неполный файл несмотря на success-сигнал от slskd.
        if not validate_audio_file(dst, source="soulseek"):
            last_error = "validation failed (size or magic bytes)"
            continue

        # Полный трек, не preview/snippet (>= 90с).
        if not validate_full_track(dst, source="soulseek"):
            last_error = "preview or short track (< 90s)"
            continue

        # ID3 match — критично для Soulseek: юзеры заливают любое аудио под
        # filename "Artist - Title.mp3" (например Cash Cash клубный микс с
        # filename "Michael Jackson - Beat It.mp3"). Проверяем теги.
        if not validate_id3_match(dst, artist, title, source="soulseek"):
            last_error = "id3 tags don't match expected artist/title"
            continue

        # Quality metadata — закрывает кейс когда expected_title ("Billie Jean")
        # чистый, ID3 artist+title пересекаются с expected, но в реальном ID3
        # title или в Soulseek-filename стоит "(Club Mix)" / "Remix" / "Extended"
        # — то есть это ремикс под видом оригинала.
        if not validate_quality_metadata(dst, filename, source="soulseek"):
            last_error = "id3 title or filename contains bad keyword (remix/live/etc.)"
            continue

        bitrate_meta, duration = _extract_metadata(dst)

        return DownloadResult(
            file_path=str(dst),
            bitrate_kbps=bitrate_meta or bitrate,
            duration_sec=duration,
            size_bytes=dst.stat().st_size,
            source="soulseek",
            soulseek_user=username,
            soulseek_filename=filename,
        )

    log.info("soulseek: all %d candidates failed, last_error=%s", len(candidates), last_error)
    return None


async def find_and_download(
    artist: str,
    title: str,
    min_bitrate_kbps: int = 192,
    max_candidates: int = 5,
    *,
    rejected_source_urls: set[str] | None = None,
) -> DownloadResult | None:
    """Async обёртка: ищет в Soulseek, скачивает первый рабочий ≥min_bitrate, перемещает в кеш."""
    return await asyncio.to_thread(
        _do_find_and_download, artist, title, min_bitrate_kbps, max_candidates, rejected_source_urls,
    )
