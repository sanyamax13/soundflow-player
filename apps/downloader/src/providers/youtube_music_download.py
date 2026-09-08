"""YouTube Music через yt-dlp + bgutil-pot (10.05.2026).

Зачем нужен. SoundCloud для топ-западных легенд = ферма cover/live/karaoke
от обычных юзеров (артисты сами не загружают). YouTube Music — где
официально лежат настоящие студийные мастеры: лейблы (Sony/Universal/Warner)
автоматически загружают весь каталог через Vevo + Topic-каналы. У всех
западных артистов есть Official Artist Channel (OAC) который объединяет
Topic+Vevo+личный канал.

Поиск: ytsearch1:<artist> <title> возвращает первый результат — обычно
Topic-канал с правильным аудио. Дополнительно фильтруем по uploader
(оканчивается на "- Topic" или Vevo).

Качество. Бесплатно YT отдаёт ~256 kbps Opus для свежих треков, ~128 Opus
для старых. AAC 256 (itag 141) только для Premium-аккаунтов с cookie.
Для нашей задачи Opus 128-256 — нормально.

PO Token. С 2024 YT требует Proof-of-Origin Token для многих стримов.
У нас в docker-compose уже стоит контейнер bgutil-pot на :4416 — он
генерирует токен. yt-dlp подключается через extractor_args.

Зависимости: yt_dlp (есть), bgutil-pot контейнер (есть), bgutil-ytdlp-pot-provider
(в pyproject уже).
"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yt_dlp  # type: ignore[import-untyped]

from ..config import config
from ._validators import (
    duration_off,
    is_alternate_version,
    validate_audio_file,
    validate_full_track,
    validate_id3_match,
    validate_quality_metadata,
)
from .soulseek_download import _file_matches, make_filename, normalize_key

log = logging.getLogger(__name__)

# Минимум 128 kbps Opus (старый Topic-каталог) — выше уже не отдают анонимам
YTM_MIN_BITRATE_KBPS = 96
# Минимум полная песня, не превью/intro
YTM_MIN_DURATION_SEC = 90
YTM_SEARCH_LIMIT = 5

# Whitelist для uploader: настоящие официальные источники у YT Music.
# Topic-каналы автоматически создаются YouTube для всех артистов из лейблов
# (Sony/Universal/Warner). Vevo — официальные музыкальные клипы.
_OFFICIAL_UPLOADER_HINTS = ("- Topic", "VEVO", "Vevo", "Official")
# Keywords that indicate a clip / live / video / cover version (not studio audio).
# Reject candidates where these appear in title/uploader BUT not in the original requested title.
_CLIP_KEYWORDS = (
    "live", "concert", "in concert", "tour",
    "official video", "music video", "music-video", "clip",
    "lyric video", "lyrics video", "visualizer",
    "karaoke", "instrumental", "cover by", "covered by",
    "live at", "live in", "live session", "acoustic version",
    "live performance", "performing live",
    "Live)", "Live]", "Live -",
)


def _is_clip_entry(entry: dict[str, Any], original_title: str) -> bool:
    """True РµСЃР»Рё Сѓ entry РІ title/uploader РµСЃС‚СЊ keyword РєР»РёРїР°,
    РєРѕС‚РѕСЂРѕРіРѕ РЅРµС‚ РІ РЅР°С€РµРј target title (Р·РЅР°С‡РёС‚ СЌС‚Рѕ Р°Р»СЊС‚РµСЂРЅР°С‚РёРІРЅР°СЏ live/cover/video РІРµСЂСЃРёСЏ)."""
    haystack = ((entry.get("title") or "") + " " + (entry.get("uploader") or "")).lower()
    original_lower = original_title.lower()
    for kw in _CLIP_KEYWORDS:
        kw_lower = kw.lower()
        if kw_lower in haystack and kw_lower not in original_lower:
            return True
    return False


@dataclass
class YTMDownloadResult:
    file_path: str
    bitrate_kbps: int | None
    duration_sec: int | None
    size_bytes: int
    source: str  # 'youtube_music'
    uploader: str
    youtube_url: str


def _yt_dlp_search_opts() -> dict[str, Any]:
    return {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": False,
        "skip_download": True,
        "ignoreerrors": True,
        "extractor_args": {
            "youtubepot-bgutilhttp": {"base_url": [config.bgutil_url]},
        },
    }


def _yt_dlp_download_opts(out_template: str) -> dict[str, Any]:
    """Скачиваем bestaudio (обычно Opus 128-256k для YouTube Music).
    НЕ перекодируем opus→mp3 — теряет качество без выгоды.

    Cookies НЕ используем (Chrome держит cookie-БД заблокированной если
    браузер открыт). Анонимный доступ работает через PO Token из bgutil-pot.
    Если в будущем понадобятся Premium-фичи (256 AAC) или age-restricted
    треки — добавим опциональный путь через Firefox cookies."""
    return {
        "quiet": True,
        "no_warnings": True,
        "format": "bestaudio[ext=m4a]/bestaudio[acodec=opus]/bestaudio",
        "outtmpl": out_template,
        "ignoreerrors": True,
        "noprogress": True,
        "writethumbnail": False,
        "writeinfojson": False,
        "extractor_args": {
            "youtubepot-bgutilhttp": {"base_url": [config.bgutil_url]},
        },
    }


def _is_official_uploader(uploader: str | None) -> bool:
    """Topic-каналы (auto-uploaded by labels) и Vevo — официальные источники."""
    if not uploader:
        return False
    return any(hint in uploader for hint in _OFFICIAL_UPLOADER_HINTS)


def _search_candidates(query: str) -> list[dict[str, Any]]:
    """ytsearch5: даёт первые 5 результатов YouTube. Поиск через ytmusic-only
    (`ytsearchmusic:`) был удалён из yt-dlp в 2024 — теперь обычный ytsearch
    с фильтром по uploader."""
    search_url = f"ytsearch{YTM_SEARCH_LIMIT}:{query}"
    try:
        with yt_dlp.YoutubeDL(_yt_dlp_search_opts()) as ydl:
            info = ydl.extract_info(search_url, download=False)
    except Exception as exc:
        log.warning("youtube_music search failed: %s", exc)
        return []

    if not info or not isinstance(info.get("entries"), list):
        return []
    return [e for e in info["entries"] if e]


def _entry_matches(entry: dict[str, Any], artist_key: str, title_key: str) -> bool:
    parts = [
        str(entry.get("title") or ""),
        str(entry.get("uploader") or ""),
        str(entry.get("channel") or ""),
        str(entry.get("webpage_url") or ""),
    ]
    combined = " ".join(parts)
    return _file_matches(combined, artist_key, title_key)


def _do_find_and_download(
    artist: str,
    title: str,
    rejected_source_urls: set[str] | None = None,
    expected_duration_sec: int | None = None,
) -> YTMDownloadResult | None:
    rejected = rejected_source_urls or set()
    artist_key = normalize_key(artist)
    title_key = normalize_key(title)
    query = f"{artist} {title}"

    log.info("youtube_music: search for %r", query)
    entries = _search_candidates(query)
    if not entries:
        log.info("youtube_music: 0 entries for %r", query)
        return None

    # Шаг 1: оставить только artist+title match
    matched = [e for e in entries if _entry_matches(e, artist_key, title_key)]
    # Reject clip/live/cover versions (anti-В«you hear words from a clipВ»).
    before_clip = len(matched)
    matched = [e for e in matched if not _is_clip_entry(e, title)]
    if before_clip != len(matched):
        log.info("youtube_music: clip-filter removed %d entries", before_clip - len(matched))
    # Reject remix/slowed/reverb alt-versions (_is_clip_entry их не ловит) —
    # тот же фильтр что в SoundCloud. Если искали ремикс — не режет.
    before_alt = len(matched)
    matched = [e for e in matched if not is_alternate_version(str(e.get("title") or ""), title)[0]]
    if before_alt != len(matched):
        log.info("youtube_music: alt-version filter removed %d entries", before_alt - len(matched))
    # Сверка длины с эталоном (Яндекс): ytsearch-entry содержит duration.
    before_dur = len(matched)
    matched = [e for e in matched if not duration_off(e.get("duration"), expected_duration_sec)]
    if before_dur != len(matched):
        log.info(
            "youtube_music: duration-filter removed %d entries (эталон %ss)",
            before_dur - len(matched), expected_duration_sec,
        )
    if not matched:
        log.info("youtube_music: %d entries но никто не совпал по фильтру", len(entries))
        return None

    # Шаг 2: приоритет — Topic/Vevo каналы (официальные)
    official = [e for e in matched if _is_official_uploader(str(e.get("uploader") or e.get("channel") or ""))]
    candidates = official if official else matched
    log.info(
        "youtube_music: %d candidates (%d official)",
        len(candidates), len(official),
    )

    cache_dir = config.track_cache_dir
    cache_dir.mkdir(parents=True, exist_ok=True)

    for entry in candidates:
        webpage_url = str(entry.get("webpage_url") or entry.get("original_url") or "")
        if not webpage_url:
            continue
        if webpage_url in rejected:
            log.info(
                "youtube_music: rejected-source skip: %s — %s source_url=%s",
                artist, title, webpage_url,
            )
            continue
        video_id = str(entry.get("id") or "ytunknown")
        temp_template = str(cache_dir / f"ytm-temp-{video_id}.%(ext)s")

        downloaded: list[Path] = []
        for attempt in range(2):
            if attempt > 0:
                import time
                time.sleep(3)
                log.info("youtube_music: retry %d для %s", attempt + 1, webpage_url)
            try:
                with yt_dlp.YoutubeDL(_yt_dlp_download_opts(temp_template)) as ydl:
                    ydl.download([webpage_url])
            except Exception as exc:
                log.warning("youtube_music: download failed for %s: %s", webpage_url, exc)
                continue
            downloaded = list(cache_dir.glob(f"ytm-temp-{video_id}.*"))
            downloaded = [p for p in downloaded if not p.name.endswith(".part")]
            if downloaded:
                break

        if not downloaded:
            log.warning("youtube_music: после 2 попыток файл не появился для %s", webpage_url)
            continue

        temp_file = downloaded[0]

        # Общая валидация (magic bytes + размер 100KB)
        if not validate_audio_file(temp_file, source="youtube_music"):
            continue

        # Полный трек, не intro/short (>= 90с)
        if not validate_full_track(temp_file, source="youtube_music"):
            continue

        # ID3 match — Topic-каналы лейблов обычно ставят правильные теги,
        # но bootleg uploads могут с filename match'нуться без правильных
        # тегов. Подстраховываемся.
        if not validate_id3_match(temp_file, artist, title, source="youtube_music"):
            continue

        if not validate_quality_metadata(temp_file, None, source="youtube_music"):
            continue

        # Метаданные через mutagen
        from mutagen import File as MutagenFile  # type: ignore
        bitrate_kbps: int | None = None
        duration_sec: int | None = None
        try:
            m = MutagenFile(str(temp_file))
            if m is not None and m.info is not None:
                br = getattr(m.info, "bitrate", None)
                if br:
                    bitrate_kbps = int(br) // 1000
                d = getattr(m.info, "length", None)
                if d:
                    duration_sec = int(d)
        except Exception as exc:
            log.warning("youtube_music: mutagen failed для %s: %s", temp_file, exc)

        if bitrate_kbps is not None and bitrate_kbps < YTM_MIN_BITRATE_KBPS:
            log.info(
                "youtube_music: пропускаем %s — bitrate %d < min %d",
                temp_file.name, bitrate_kbps, YTM_MIN_BITRATE_KBPS,
            )
            try:
                temp_file.unlink()
            except OSError:
                pass
            continue

        # Финальное имя
        ext = temp_file.suffix
        final_name = make_filename(artist, title, ext=ext)
        final_path = cache_dir / final_name
        if final_path.exists() and final_path != temp_file:
            try:
                final_path.unlink()
            except OSError:
                pass
        try:
            temp_file.rename(final_path)
        except OSError as exc:
            log.warning("youtube_music: rename failed %s -> %s: %s", temp_file, final_path, exc)
            continue

        size_bytes = final_path.stat().st_size
        return YTMDownloadResult(
            file_path=str(final_path),
            bitrate_kbps=bitrate_kbps,
            duration_sec=duration_sec,
            size_bytes=size_bytes,
            source="youtube_music",
            uploader=str(entry.get("uploader") or entry.get("channel") or "unknown"),
            youtube_url=webpage_url,
        )

    log.info("youtube_music: ни один кандидат не скачался для %r", query)
    return None


async def find_and_download(
    artist: str,
    title: str,
    *,
    rejected_source_urls: set[str] | None = None,
    expected_duration_sec: int | None = None,
) -> YTMDownloadResult | None:
    return await asyncio.to_thread(
        _do_find_and_download, artist, title, rejected_source_urls, expected_duration_sec
    )
