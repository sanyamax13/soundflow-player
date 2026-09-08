"""Поиск и скачивание трека через SoundCloud (yt-dlp).

Используется как fallback после Soulseek в find_audio_chain.
SoundCloud анонимно даёт 128 kbps mp3 или 64 kbps opus — не идеально,
но артисты сами заливают свои треки (Гуф, Баста, MACAN — есть).

В отличие от Soulseek-провайдера, scdl не используем — он сам признан
архивированным wrapper'ом над yt-dlp. yt-dlp активно поддерживается
(последний фикс soundcloud-extractor 30.04.2026).
"""
from __future__ import annotations

import asyncio
import logging
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yt_dlp  # type: ignore[import-untyped]
from yt_dlp.networking.impersonate import ImpersonateTarget  # type: ignore[import-untyped]

from ..config import config
from ._validators import (
    duration_off,
    is_alternate_version,
    validate_audio_file,
    validate_full_track,
    validate_id3_match,
    validate_quality_metadata,
)
from .soulseek_download import (
    _FORBIDDEN_FS_CHARS,
    _file_matches,
    make_filename,
    normalize_key,
)

log = logging.getLogger(__name__)

# Минимальный битрейт для SoundCloud — 128 (анонимно SC выше не отдаёт)
SC_MIN_BITRATE_KBPS = 128
# Минимальная длительность — отсекает превью/radio-edit (Billie Jean 29 сек, БАНК 1:45)
SC_MIN_DURATION_SEC = 120
SC_DOWNLOAD_TIMEOUT_SEC = 60.0
SC_SEARCH_LIMIT = 5
# SoundCloud (середина 2026) рвёт TLS-хендшейк обычного yt-dlp (UNEXPECTED_EOF) —
# фингерпринтит не-браузерные клиенты. Лечится impersonate (yt-dlp гоняет запрос
# через curl_cffi с TLS-отпечатком Chrome). Требует curl_cffi в версии, совместимой
# с yt-dlp (<0.15 для 2026.3.17) — см. pyproject. Без этого SoundCloud отдаёт 0.
SC_IMPERSONATE = ImpersonateTarget(client="chrome")
# curl_cffi 0.14 на этой машине ~1 из 8 запросов кидает 'invalid library'
# (BoringSSL иногда не инициализируется) — чисто транзиентно, ретрай проходит.
# Без ретрая поиск отдавал [] → трек «не найден» (хотя на SoundCloud он есть).
SC_SEARCH_RETRY = 4


def _is_transient_tls(exc: Exception) -> bool:
    s = str(exc).lower()
    return any(
        m in s
        for m in (
            "invalid library",
            "tls connect error",
            "unexpected_eof",
            "curl: (35)",
            "curl: (56)",
            "curl: (92)",
        )
    )


@dataclass
class SCDownloadResult:
    file_path: str
    bitrate_kbps: int | None
    duration_sec: int | None
    size_bytes: int
    source: str  # 'soundcloud'
    soundcloud_user: str
    soundcloud_url: str


def _yt_dlp_search_opts() -> dict[str, Any]:
    """SoundCloud работает анонимно — cookies от Chrome не нужны и часто
    мешают (Chrome держит cookie-БД заблокированной)."""
    return {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": False,
        "skip_download": True,
        "ignoreerrors": True,
        "impersonate": SC_IMPERSONATE,
    }


def _yt_dlp_download_opts(out_template: str) -> dict[str, Any]:
    """Настройки для скачивания. Берём mp3 если есть в форматах, иначе любой
    bestaudio (может быть opus). Перекодирование opus→mp3 НЕ делаем — это
    lossy→lossy, теряем качество ради расширения."""
    return {
        "quiet": True,
        "no_warnings": True,
        "format": "bestaudio[ext=mp3]/bestaudio[acodec=mp3]/bestaudio",
        "outtmpl": out_template,
        "ignoreerrors": True,
        "noprogress": True,
        "writethumbnail": False,
        "writeinfojson": False,
        "impersonate": SC_IMPERSONATE,
    }


def _search_candidates(query: str) -> list[dict[str, Any]]:
    """Ищет на SoundCloud через yt-dlp scsearch. Возвращает entries."""
    search_url = f"scsearch{SC_SEARCH_LIMIT}:{query}"
    info = None
    for attempt in range(SC_SEARCH_RETRY):
        try:
            with yt_dlp.YoutubeDL(_yt_dlp_search_opts()) as ydl:
                info = ydl.extract_info(search_url, download=False)
            break
        except Exception as exc:
            if _is_transient_tls(exc) and attempt < SC_SEARCH_RETRY - 1:
                log.info(
                    "soundcloud search transient (попытка %d/%d): %s",
                    attempt + 1, SC_SEARCH_RETRY, exc,
                )
                continue
            log.warning("soundcloud search failed: %s", exc)
            return []

    if not info or not isinstance(info.get("entries"), list):
        return []
    # Очистим None entries (yt-dlp с ignoreerrors может вставлять пустые)
    return [e for e in info["entries"] if e]


def _entry_matches(entry: dict[str, Any], artist_key: str, title_key: str) -> bool:
    """Проверка что трек реально подходит — artist+title встречаются в title или uploader."""
    parts = [
        str(entry.get("title") or ""),
        str(entry.get("uploader") or ""),
        str(entry.get("uploader_id") or ""),
        str(entry.get("webpage_url") or ""),
    ]
    combined = " ".join(parts)
    return _file_matches(combined, artist_key, title_key)


def _audio_meta(file_path: Path) -> tuple[int | None, int | None, int]:
    """Возвращает (bitrate_kbps, duration_sec, size_bytes) через mutagen."""
    size_bytes = file_path.stat().st_size
    try:
        from mutagen import File as MutagenFile  # type: ignore

        m = MutagenFile(str(file_path))
        if m is None:
            return None, None, size_bytes
        info = getattr(m, "info", None)
        bitrate_kbps: int | None = None
        duration_sec: int | None = None
        if info is not None:
            br = getattr(info, "bitrate", None)
            if br:
                bitrate_kbps = int(br) // 1000
            dur = getattr(info, "length", None)
            if dur:
                duration_sec = int(dur)
        return bitrate_kbps, duration_sec, size_bytes
    except Exception as exc:
        log.warning("mutagen meta failed for %s: %s", file_path, exc)
        return None, None, size_bytes


def _do_find_and_download(
    artist: str,
    title: str,
    rejected_source_urls: set[str] | None = None,
    expected_duration_sec: int | None = None,
) -> SCDownloadResult | None:
    rejected = rejected_source_urls or set()
    artist_key = normalize_key(artist)
    title_key = normalize_key(title)
    query = f"{artist} {title}"

    log.info("soundcloud: search for %r", query)
    entries = _search_candidates(query)
    if not entries:
        log.info("soundcloud: 0 entries for %r", query)
        return None

    # Фильтр и сортировка — берём кандидатов где artist+title матчатся
    candidates = [e for e in entries if _entry_matches(e, artist_key, title_key)]
    if not candidates:
        log.info("soundcloud: %d entries но никто не совпал по фильтру", len(entries))
        return None

    # Отсекаем перезаливы-альтернативы (remix/slowed/cover/...) которые на SC
    # подписаны именем оригинала: «HOLLYFLAME - Тону (Konkin remix)» матчится
    # по artist+title, но это не та версия. Если мы сами искали ремикс
    # (в title есть keyword) — is_alternate_version их НЕ режет.
    before_alt = len(candidates)
    kept = []
    for e in candidates:
        is_alt, reason = is_alternate_version(str(e.get("title") or ""), title)
        if is_alt:
            log.info("soundcloud: skip alt-version %r (%s)", e.get("title"), reason)
            continue
        # Сверка длины с эталоном (Яндекс): отбрасываем версии не той длины
        # (обрезки/чужие записи под тем же именем). duration есть в scsearch-entry.
        if duration_off(e.get("duration"), expected_duration_sec):
            log.info(
                "soundcloud: skip wrong-duration %r (%ss vs эталон %ss)",
                e.get("title"), e.get("duration"), expected_duration_sec,
            )
            continue
        kept.append(e)
    candidates = kept
    if not candidates:
        log.info("soundcloud: все %d кандидата отфильтрованы (версия/длина), пропускаю SC", before_alt)
        return None

    log.info("soundcloud: %d отфильтрованных кандидатов", len(candidates))

    cache_dir = config.track_cache_dir
    cache_dir.mkdir(parents=True, exist_ok=True)

    for entry in candidates:
        webpage_url = str(entry.get("webpage_url") or entry.get("original_url") or "")
        if not webpage_url:
            continue
        if webpage_url in rejected:
            log.info(
                "soundcloud: rejected-source skip: %s — %s source_url=%s",
                artist, title, webpage_url,
            )
            continue
        track_id = str(entry.get("id") or "scunknown")
        # Временное имя — yt-dlp сам подставит расширение через %(ext)s
        temp_template = str(cache_dir / f"sc-temp-{track_id}.%(ext)s")

        # SoundCloud периодически отдаёт SSL EOF (rate limit / CDN flap),
        # yt-dlp в этом случае пишет ERROR в лог но не бросает исключение —
        # файла на диске не появляется. Делаем 2 попытки с задержкой.
        downloaded: list[Path] = []
        for attempt in range(2):
            if attempt > 0:
                import time
                time.sleep(3)
                log.info("soundcloud: retry %d для %s", attempt + 1, webpage_url)
            try:
                with yt_dlp.YoutubeDL(_yt_dlp_download_opts(temp_template)) as ydl:
                    ydl.download([webpage_url])
            except Exception as exc:
                log.warning("soundcloud: download failed for %s: %s", webpage_url, exc)
                continue
            downloaded = list(cache_dir.glob(f"sc-temp-{track_id}.*"))
            downloaded = [p for p in downloaded if not p.name.endswith(".part")]
            if downloaded:
                break

        if not downloaded:
            log.warning("soundcloud: после %d попыток файл не появился для %s", 2, webpage_url)
            continue

        temp_file = downloaded[0]

        # Общая валидация (размер + magic bytes). yt-dlp иногда оставляет
        # обрезанные .part-файлы или html-странички вместо медиа.
        if not validate_audio_file(temp_file, source="soundcloud"):
            continue

        # Защита от 30-секундных radio-edit / preview / snippet — независимо
        # от того что говорят SC_MIN_DURATION_SEC и _audio_meta. Это последняя
        # линия обороны: читает duration сам, удаляет файл если <= 45с.
        if not validate_full_track(temp_file, source="soundcloud"):
            continue

        # ID3 match — на SC юзер мог залить «Beatles - Hey Jude» а внутри
        # cover-версия. Проверяем теги.
        if not validate_id3_match(temp_file, artist, title, source="soundcloud"):
            continue

        if not validate_quality_metadata(temp_file, None, source="soundcloud"):
            continue

        ext = temp_file.suffix
        bitrate, duration, size = _audio_meta(temp_file)

        if bitrate is not None and bitrate < SC_MIN_BITRATE_KBPS:
            log.info("soundcloud: пропускаем %s — bitrate %d < min %d", temp_file.name, bitrate, SC_MIN_BITRATE_KBPS)
            try:
                temp_file.unlink()
            except OSError:
                pass
            continue

        if duration is not None and duration < SC_MIN_DURATION_SEC:
            log.info(
                "soundcloud: пропускаем %s — duration %d сек < min %d (превью/radio-edit)",
                temp_file.name, duration, SC_MIN_DURATION_SEC,
            )
            try:
                temp_file.unlink()
            except OSError:
                pass
            continue

        # Финальное имя
        final_name = make_filename(artist, title, ext=ext)
        final_path = cache_dir / final_name
        # Если уже есть с таким именем — удалить старый
        if final_path.exists() and final_path != temp_file:
            try:
                final_path.unlink()
            except OSError:
                pass
        try:
            temp_file.rename(final_path)
        except OSError as exc:
            log.warning("soundcloud: не смог переименовать %s -> %s: %s", temp_file, final_path, exc)
            continue

        return SCDownloadResult(
            file_path=str(final_path),
            bitrate_kbps=bitrate,
            duration_sec=duration,
            size_bytes=size,
            source="soundcloud",
            soundcloud_user=str(entry.get("uploader") or "unknown"),
            soundcloud_url=webpage_url,
        )

    log.info("soundcloud: ни один кандидат не скачался для %r", query)
    return None


async def find_and_download(
    artist: str,
    title: str,
    *,
    rejected_source_urls: set[str] | None = None,
    expected_duration_sec: int | None = None,
) -> SCDownloadResult | None:
    return await asyncio.to_thread(
        _do_find_and_download, artist, title, rejected_source_urls, expected_duration_sec
    )
