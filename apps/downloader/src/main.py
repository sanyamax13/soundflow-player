from __future__ import annotations
import asyncio
import logging
from typing import Any, Literal
from urllib.parse import urlparse, parse_qs

import yt_dlp  # type: ignore[import-untyped]
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from .chart_routes import router as chart_router
from .config import config

logging.basicConfig(
    level=config.log_level,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("sidecar")

app = FastAPI(title="SoundFlow Python Sidecar", version="2.0.0a0")
# Чарт-эндпоинты вынесены в chart_routes.py (изолированная группа парсеров).
app.include_router(chart_router)

# Лимит одновременных исходящих запросов (поиск+resolve через провайдеров).
# 3 — баланс между скоростью поиска и нагрузкой на домашний роутер с Mihomo:
# фронт стучит в 6 провайдеров параллельно, без лимита это 6 одновременных
# исходящих соединений, роутер не справляется. См. memory/project_mihomo_constraint.md.
_OUTBOUND_LIMIT = asyncio.Semaphore(3)


@app.get("/health")
async def health() -> dict[str, str]:
    return {
        "status": "ok",
        "service": "soundflow-python-sidecar",
        "version": "2.0.0a0",
    }


ProviderName = Literal["soundcloud", "youtube", "rutube", "soulseek"]
ResolvableProvider = Literal["soundcloud", "youtube", "rutube"]


class SearchRequest(BaseModel):
    provider: ProviderName
    query: str
    limit: int = 10


class SearchItem(BaseModel):
    provider: ProviderName
    provider_track_id: str
    provider_url: str
    artist: str
    title: str
    duration_sec: int | None
    cover_url: str | None
    stream_url: str | None


class SearchResponse(BaseModel):
    items: list[SearchItem]


class ResolveRequest(BaseModel):
    provider: ResolvableProvider
    provider_url: str


class ResolveResponse(BaseModel):
    stream_url: str
    expires_at: int | None


class SoulseekDownloadRequest(BaseModel):
    artist: str
    title: str
    min_bitrate_kbps: int = 192
    max_candidates: int = 5


class SoulseekDownloadResponse(BaseModel):
    found: bool
    file_path: str | None = None
    bitrate_kbps: int | None = None
    duration_sec: int | None = None
    size_bytes: int | None = None
    source: str | None = None
    soulseek_user: str | None = None
    error: str | None = None


@app.post("/search", response_model=SearchResponse)
async def search(req: SearchRequest) -> SearchResponse:
    log.info("search provider=%s query=%r limit=%d", req.provider, req.query, req.limit)
    async with _OUTBOUND_LIMIT:
        if req.provider == "soundcloud":
            from .providers.soundcloud import search_soundcloud
            items = await search_soundcloud(req.query, req.limit)
        elif req.provider == "youtube":
            from .providers.youtube import search_youtube
            items = await search_youtube(req.query, req.limit)
        elif req.provider == "rutube":
            from .providers.rutube import search_rutube
            items = await search_rutube(req.query, req.limit)
        elif req.provider == "soulseek":
            from .providers.soulseek import search_soulseek
            items = await search_soulseek(req.query, req.limit)
        else:
            raise HTTPException(status_code=400, detail=f"unknown provider: {req.provider}")
    return SearchResponse(items=items)


_RESOLVE_OPTS: dict[str, Any] = {
    "quiet": True,
    "no_warnings": True,
    "skip_download": True,
    "format": "bestaudio/best",
    "ignoreerrors": True,
    "extractor_args": {
        "youtubepot-bgutilhttp": {"base_url": [config.bgutil_url]},
    },
}
if config.yt_cookies_browser:
    _RESOLVE_OPTS["cookiesfrombrowser"] = (config.yt_cookies_browser,)


def _parse_expire(url: str) -> int | None:
    try:
        parsed = urlparse(url)
        qs = parse_qs(parsed.query)
        v = qs.get("expire") or qs.get("expires") or qs.get("Expires")
        if v:
            return int(v[0])
        # YouTube live HLS кладёт expire в path (`/expire/<ts>/`)
        parts = parsed.path.split("/")
        for i, seg in enumerate(parts):
            if seg == "expire" and i + 1 < len(parts) and parts[i + 1].isdigit():
                return int(parts[i + 1])
        return None
    except (ValueError, TypeError):
        return None


def _resolve_sync(provider_url: str) -> str | None:
    try:
        with yt_dlp.YoutubeDL(_RESOLVE_OPTS) as ydl:
            info: dict[str, Any] = ydl.extract_info(provider_url, download=False)
    except Exception as exc:
        log.warning("resolve failed for %s: %s", provider_url, exc)
        return None
    return info.get("url") if isinstance(info, dict) else None


@app.post("/resolve", response_model=ResolveResponse)
async def resolve(req: ResolveRequest) -> ResolveResponse:
    log.info("resolve provider=%s url=%s", req.provider, req.provider_url)
    async with _OUTBOUND_LIMIT:
        stream_url = await asyncio.to_thread(_resolve_sync, req.provider_url)
    if not stream_url:
        raise HTTPException(status_code=502, detail="resolve failed")
    return ResolveResponse(stream_url=stream_url, expires_at=_parse_expire(stream_url))


@app.post("/soulseek/find-and-download", response_model=SoulseekDownloadResponse)
async def soulseek_find_and_download(
    req: SoulseekDownloadRequest,
) -> SoulseekDownloadResponse:
    """Старый endpoint — оставлен для совместимости, не используется в новой
    цепочке. Используй /find-audio (audio_chain) вместо него."""
    log.info("soulseek find+download: artist=%r title=%r", req.artist, req.title)
    from .providers.soulseek_download import find_and_download
    async with _OUTBOUND_LIMIT:
        result = await find_and_download(
            req.artist, req.title, req.min_bitrate_kbps, req.max_candidates,
        )
    if result is None:
        return SoulseekDownloadResponse(found=False)
    return SoulseekDownloadResponse(
        found=True,
        file_path=config.to_canonical(result.file_path),
        bitrate_kbps=result.bitrate_kbps,
        duration_sec=result.duration_sec,
        size_bytes=result.size_bytes,
        source=result.source,
        soulseek_user=result.soulseek_user,
    )


class FindAudioRequest(BaseModel):
    artist: str
    title: str
    # Skip-list провайдеров (имена как в audio_chain). Используется для
    # топ-западных легенд: SoundCloud для них = cover/live/karaoke ферма,
    # лучше пойти сразу в rutracker. По умолчанию пусто = используем все.
    skip_providers: list[str] = []
    # Source URLs которые уже отклонены для этого трека (см. таблицу
    # rejected_track_files в БД на TS-стороне). Провайдеры пропустят
    # кандидата если его source_url есть в этом списке. Без этого после
    # удаления плохого файла через cleanup-bad-track-files.ts система
    # снова бы вернула тот же мусор.
    rejected_source_urls: list[str] = []
    # Эталонная длительность трека (сек). Если задана — chain отбрасывает
    # версии не той длины (ремикс/обрезка). Если None — sidecar сам спросит
    # Яндекс по artist+title.
    expected_duration_sec: int | None = None


class ExtraTrack(BaseModel):
    file_path: str
    artist: str
    title: str
    album: str | None = None
    duration_sec: int | None = None
    bitrate_kbps: int | None = None
    size_bytes: int


class FindAudioResponse(BaseModel):
    found: bool
    file_path: str | None = None
    bitrate_kbps: int | None = None
    duration_sec: int | None = None
    size_bytes: int | None = None
    source: str | None = None
    provider_user: str | None = None
    provider_url: str | None = None
    # Дополнительные mp3 из того же альбома (только для rutracker_album)
    extra_tracks: list[ExtraTrack] = []


class AnalyzeFeaturesRequest(BaseModel):
    file_path: str


class AnalyzeFeaturesResponse(BaseModel):
    found: bool
    embedding: list[float] | None = None  # 2048 floats или None если не получилось


@app.post("/analyze-features", response_model=AnalyzeFeaturesResponse)
async def analyze_features(req: AnalyzeFeaturesRequest) -> AnalyzeFeaturesResponse:
    """Считает PANNs CNN14 embedding (2048-D) для mp3-файла.

    Используется для алгоритма «Твой Вайб». Зовётся ленивым hook'ом из api
    после первого resolve трека. Inference на CPU ~1-2 сек (плюс librosa load
    для 3-минутного mp3 ~3 сек).
    """
    log.info("analyze-features: %s", req.file_path)
    from .providers.audio_features import analyze_audio

    # API передаёт CANONICAL path; на fg читаем по LOCAL physical. На brain no-op.
    vec = await analyze_audio(config.to_local(req.file_path))
    if vec is None:
        return AnalyzeFeaturesResponse(found=False)
    return AnalyzeFeaturesResponse(found=True, embedding=vec)


class AnalyzeLoudnessRequest(BaseModel):
    file_path: str


class AnalyzeLoudnessResponse(BaseModel):
    found: bool
    integrated_lufs: float | None = None
    true_peak_db: float | None = None


@app.post("/analyze-loudness", response_model=AnalyzeLoudnessResponse)
async def analyze_loudness(req: AnalyzeLoudnessRequest) -> AnalyzeLoudnessResponse:
    """Считает громкость трека (LUFS + true peak) через ffmpeg loudnorm.

    Spotify-style normalization. Зовётся при первом resolve трека или
    backfill-скриптом. ffmpeg один проход 2-5 сек на 3-4 мин mp3."""
    log.info("analyze-loudness: %s", req.file_path)
    from .providers.loudness import analyze_loudness as _do_analyze

    # API передаёт CANONICAL path; на fg читаем по LOCAL physical. На brain no-op.
    result = await _do_analyze(config.to_local(req.file_path))
    if result is None:
        return AnalyzeLoudnessResponse(found=False)
    return AnalyzeLoudnessResponse(
        found=True,
        integrated_lufs=result.integrated_lufs,
        true_peak_db=result.true_peak_db,
    )


class YandexArtistRequest(BaseModel):
    name: str
    with_tracks: bool = True


class YandexArtistTrack(BaseModel):
    title: str
    duration_sec: int | None = None


class YandexArtistResponse(BaseModel):
    found: bool
    name: str | None = None
    photo_url: str | None = None
    yandex_id: str | None = None
    top_tracks: list[YandexArtistTrack] = []


@app.post("/yandex/search-artist", response_model=YandexArtistResponse)
async def yandex_search_artist(req: YandexArtistRequest) -> YandexArtistResponse:
    """Поиск артиста в Яндекс Музыке → имя + фото + топ-треки. Для онбординга:
    русских артистов и их фото Deezer почти не знает, Яндекс знает отлично."""
    from .providers.yandex import search_artist
    r = await search_artist(req.name, req.with_tracks)
    if not r:
        return YandexArtistResponse(found=False)
    return YandexArtistResponse(
        found=True,
        name=r["name"],
        photo_url=r["photo_url"],
        yandex_id=r["yandex_id"],
        top_tracks=[YandexArtistTrack(**t) for t in r["top_tracks"]],
    )


class YandexCoverRequest(BaseModel):
    artist: str
    title: str


class YandexCoverResponse(BaseModel):
    found: bool
    cover_url: str | None = None


@app.post("/yandex/track-cover", response_model=YandexCoverResponse)
async def yandex_track_cover(req: YandexCoverRequest) -> YandexCoverResponse:
    """Обложка трека в Яндекс Музыке по артист+название. Для дозакачки обложек
    песням без картинки ни в одном источнике (в осн. русские — iTunes/Deezer их
    плохо знают). Возвращает URL картинки на avatars.yandex.net (качает сервер)."""
    from .providers.yandex import find_track_cover
    url = await find_track_cover(req.artist, req.title)
    return YandexCoverResponse(found=bool(url), cover_url=url)


@app.post("/find-audio", response_model=FindAudioResponse)
async def find_audio(req: FindAudioRequest) -> FindAudioResponse:
    """Универсальный поиск+скачивание через цепочку источников.

    rejected_source_urls — список URL источников которые уже отклонены
    для этого трека (TS-сторона передаёт из rejected_track_files).
    Провайдеры пропустят кандидата с таким source_url.
    """
    log.info(
        "find-audio: artist=%r title=%r skip=%r rejected=%d",
        req.artist, req.title, req.skip_providers, len(req.rejected_source_urls),
    )
    from .providers.audio_chain import find_audio_chain
    async with _OUTBOUND_LIMIT:
        result = await find_audio_chain(
            req.artist, req.title,
            skip_providers=set(req.skip_providers),
            rejected_source_urls=set(req.rejected_source_urls),
            expected_duration_sec=req.expected_duration_sec,
        )
    if result is None:
        return FindAudioResponse(found=False)
    # Stage 2 path translation: sidecar пишет в LOCAL physical dir, но API/БД
    # хранят CANONICAL path. На brain no-op (canonical == local).
    return FindAudioResponse(
        found=True,
        file_path=config.to_canonical(result.file_path),
        bitrate_kbps=result.bitrate_kbps,
        duration_sec=result.duration_sec,
        size_bytes=result.size_bytes,
        source=result.source,
        provider_user=result.provider_user,
        provider_url=result.provider_url,
        extra_tracks=[
            ExtraTrack(**{**et, "file_path": config.to_canonical(et["file_path"])})
            for et in result.extra_tracks
        ],
    )


class Id3InfoRequest(BaseModel):
    file_path: str


class Id3InfoResponse(BaseModel):
    title: str | None = None
    artist: str | None = None


@app.post("/id3-info", response_model=Id3InfoResponse)
async def id3_info(req: Id3InfoRequest) -> Id3InfoResponse:
    """Read ID3 tags (artist+title) from a local audio file.

    Used by API tracks.resolve to detect when the canonical track name
    differs from the actual ID3 (e.g. remix versions). Lightweight: only
    artist+title strings, no full metadata dump.
    """
    physical = config.to_local(req.file_path) or req.file_path
    try:
        from pathlib import Path
        from mutagen import File as MutagenFile  # type: ignore
        from mutagen.easyid3 import EasyID3  # type: ignore

        p = Path(physical)
        if not p.exists():
            return Id3InfoResponse()
        title = ""
        artist = ""
        try:
            if str(p).lower().endswith(".mp3"):
                t = EasyID3(str(p))
                title = (t.get("title") or [""])[0]
                artist = (t.get("artist") or [""])[0]
        except Exception:
            pass
        if not title or not artist:
            m = MutagenFile(str(p))
            if m is not None and m.tags is not None:
                td = dict(m.tags)
                for k in ("TITLE", "\xa9nam", "title"):
                    v = td.get(k)
                    if v:
                        title = str(v[0] if isinstance(v, list) else v)
                        break
                for k in ("ARTIST", "\xa9ART", "artist"):
                    v = td.get(k)
                    if v:
                        artist = str(v[0] if isinstance(v, list) else v)
                        break
        return Id3InfoResponse(title=title or None, artist=artist or None)
    except Exception as e:
        log.warning("id3-info failed for %s: %s", physical, e)
        return Id3InfoResponse()


class ImportUrlRequest(BaseModel):
    url: str


class ImportUrlResponse(BaseModel):
    found: bool
    file_path: str | None = None
    artist: str | None = None
    title: str | None = None
    duration_sec: int | None = None
    bitrate_kbps: int | None = None
    size_bytes: int | None = None
    source_url: str | None = None
    error: str | None = None


class ImportPlaylistRequest(BaseModel):
    url: str


class ImportPlaylistEntry(BaseModel):
    url: str
    title: str | None = None
    artist: str | None = None
    duration: int | None = None


class ImportPlaylistResponse(BaseModel):
    found: bool
    playlist_title: str | None = None
    entries: list[ImportPlaylistEntry] = []
    error: str | None = None


@app.post("/import-playlist", response_model=ImportPlaylistResponse)
async def import_playlist(req: ImportPlaylistRequest) -> ImportPlaylistResponse:
    """Flat extract плейлиста через yt-dlp.

    Возвращает list of {url, title, artist, duration} БЕЗ скачивания файлов.
    Используется для импорта плейлистов из VK/Yandex/Zvuk/SoundCloud/YouTube.
    Дальше API делает importByUrl для каждой entry поэтапно.
    """
    opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": "in_playlist",  # не качать аудио, только метаданные
        "ignoreerrors": True,
        "noprogress": True,
        "extractor_args": {
            "youtubepot-bgutilhttp": {"base_url": [config.bgutil_url]},
        },
    }

    def _do_extract() -> tuple[dict[str, object] | None, str | None]:
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(req.url, download=False)
            if not info or not isinstance(info, dict):
                return None, "no info"
            return info, None
        except Exception as e:
            return None, str(e)

    async with _OUTBOUND_LIMIT:
        info, error = await asyncio.to_thread(_do_extract)

    if error or not info:
        return ImportPlaylistResponse(found=False, error=error or "unknown error")

    raw_entries = info.get("entries") or []
    if not raw_entries:
        # Возможно это одиночный URL, не playlist
        return ImportPlaylistResponse(
            found=False,
            error="no entries (one-track URL? используй /import-url)",
        )

    entries: list[ImportPlaylistEntry] = []
    for raw in raw_entries:
        if not isinstance(raw, dict):
            continue
        entry_url = raw.get("url") or raw.get("webpage_url")
        if not entry_url:
            continue
        entries.append(
            ImportPlaylistEntry(
                url=str(entry_url),
                title=raw.get("title") and str(raw.get("title")),
                artist=raw.get("uploader") and str(raw.get("uploader")),
                duration=int(raw["duration"]) if isinstance(raw.get("duration"), (int, float)) else None,
            )
        )

    playlist_title = info.get("title") and str(info.get("title"))
    return ImportPlaylistResponse(
        found=True,
        playlist_title=playlist_title,
        entries=entries,
    )


@app.post("/import-url", response_model=ImportUrlResponse)
async def import_url(req: ImportUrlRequest) -> ImportUrlResponse:
    """Download an arbitrary URL (YouTube/SoundCloud/direct mp3) via yt-dlp.
    Returns metadata + file_path for API to register in track_files/tracks.
    """
    from pathlib import Path

    cache_dir = config.track_cache_dir
    cache_dir.mkdir(parents=True, exist_ok=True)
    out_template = str(cache_dir / "import-%(id)s.%(ext)s")

    opts = {
        "quiet": True,
        "no_warnings": True,
        "format": "bestaudio[ext=m4a]/bestaudio[acodec=opus]/bestaudio",
        "outtmpl": out_template,
        "ignoreerrors": True,
        "noprogress": True,
        "extractor_args": {
            "youtubepot-bgutilhttp": {"base_url": [config.bgutil_url]},
        },
    }

    def _do_download() -> tuple[Path | None, dict[str, object] | None, str | None]:
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(req.url, download=True)
            if not info or not isinstance(info, dict):
                return None, None, "no info"
            video_id = str(info.get("id") or "unknown")
            files = list(cache_dir.glob(f"import-{video_id}.*"))
            files = [p for p in files if not p.name.endswith(".part")]
            if not files:
                return None, info, "file not created"
            return files[0], info, None
        except Exception as e:
            return None, None, str(e)

    async with _OUTBOUND_LIMIT:
        file_path, info, error = await asyncio.to_thread(_do_download)

    if error or not file_path or not info:
        return ImportUrlResponse(found=False, error=error or "unknown error")

    # Базовая валидация (magic bytes + size)
    from .providers._validators import validate_audio_file, validate_full_track

    if not validate_audio_file(file_path, source="import_url"):
        return ImportUrlResponse(found=False, error="invalid audio file")
    if not validate_full_track(file_path, source="import_url"):
        return ImportUrlResponse(found=False, error="too short (likely preview)")

    # Метаданные через mutagen
    bitrate = None
    duration = None
    try:
        from mutagen import File as MutagenFile  # type: ignore
        m = MutagenFile(str(file_path))
        if m is not None and m.info is not None:
            br = getattr(m.info, "bitrate", None)
            if br:
                bitrate = int(br) // 1000
            d = getattr(m.info, "length", None)
            if d:
                duration = int(d)
    except Exception:
        pass

    artist = str(info.get("uploader") or info.get("creator") or info.get("artist") or "Unknown")
    title = str(info.get("title") or file_path.stem)
    webpage_url = str(info.get("webpage_url") or info.get("original_url") or req.url)
    size = file_path.stat().st_size

    return ImportUrlResponse(
        found=True,
        file_path=config.to_canonical(str(file_path)),
        artist=artist,
        title=title,
        duration_sec=duration,
        bitrate_kbps=bitrate,
        size_bytes=size,
        source_url=webpage_url,
    )


class MusifyFindRequest(BaseModel):
    artist: str
    title: str


class MusifyFindResponse(BaseModel):
    found: bool
    artist: str | None = None
    title: str | None = None
    download_url: str | None = None
    track_url: str | None = None
    bitrate_kbps: int | None = None
    duration_sec: int | None = None
    score: float | None = None
    error: str | None = None


class MusifyDownloadResponse(BaseModel):
    found: bool
    file_path: str | None = None
    artist: str | None = None
    title: str | None = None
    bitrate_kbps: int | None = None
    duration_sec: int | None = None
    size_bytes: int | None = None
    source_url: str | None = None
    error: str | None = None


@app.post("/musify-download", response_model=MusifyDownloadResponse)
async def musify_download(req: MusifyFindRequest) -> MusifyDownloadResponse:
    """Поиск + скачивание трека с musify.club. Возвращает canonical file_path."""
    try:
        from .providers.musify import download_track
        result = await download_track(req.artist, req.title, config.track_cache_dir)
        if result is None:
            return MusifyDownloadResponse(found=False, error="no match or download failed")
        file_path, match = result
        from pathlib import Path
        size = Path(file_path).stat().st_size
        return MusifyDownloadResponse(
            found=True,
            file_path=config.to_canonical(file_path),
            artist=match.artist,
            title=match.title,
            bitrate_kbps=match.bitrate_kbps,
            duration_sec=match.duration_sec,
            size_bytes=size,
            source_url=match.track_url,
        )
    except Exception as e:
        log.warning("musify-download failed: %s", e)
        return MusifyDownloadResponse(found=False, error=str(e))


@app.post("/musify-find", response_model=MusifyFindResponse)
async def musify_find(req: MusifyFindRequest) -> MusifyFindResponse:
    """Поиск трека на musify.club. Возвращает прямую mp3 ссылку (без авторизации)."""
    try:
        from .providers.musify import find_track
        m = await find_track(req.artist, req.title)
        if m is None:
            return MusifyFindResponse(found=False, error="no match")
        return MusifyFindResponse(
            found=True,
            artist=m.artist,
            title=m.title,
            download_url=m.download_url,
            track_url=m.track_url,
            bitrate_kbps=m.bitrate_kbps,
            duration_sec=m.duration_sec,
            score=m.score,
        )
    except Exception as e:
        log.warning("musify-find failed: %s", e)
        return MusifyFindResponse(found=False, error=str(e))


class UmapProjectionRequest(BaseModel):
    pass


class UmapPoint(BaseModel):
    id: str
    artist: str
    title: str
    cover_url: str | None
    x: float
    y: float


class UmapProjectionResponse(BaseModel):
    points: list[UmapPoint]
    error: str | None = None


# Кэш (in-memory, TTL 1 час).
_UMAP_CACHE: dict[str, object] = {"data": None, "ts": 0.0}


@app.post("/umap-projection", response_model=UmapProjectionResponse)
async def umap_projection(req: UmapProjectionRequest) -> UmapProjectionResponse:
    """Возвращает 2D-проекцию embeddings всех треков через UMAP.
    Тянет embeddings прямо из Postgres (через asyncpg, минуя API).
    Кэш 1 час чтобы не пересчитывать на каждом запросе.
    """
    import time
    if _UMAP_CACHE["data"] is not None and (time.time() - _UMAP_CACHE["ts"]) < 3600:
        return UmapProjectionResponse(points=_UMAP_CACHE["data"])  # type: ignore[arg-type]

    try:
        import os
        import asyncpg  # type: ignore[import-untyped]
        import numpy as np
        import umap  # type: ignore[import-untyped]

        dsn = os.environ.get("DATABASE_URL", "postgres://soundflow:soundflow@127.0.0.1:5432/soundflow")
        conn = await asyncpg.connect(dsn)
        try:
            rows = await conn.fetch(
                "SELECT id::text, artist, title, cover_url, feature_vector::text "
                "FROM tracks WHERE feature_vector IS NOT NULL ORDER BY created_at DESC"
            )
        finally:
            await conn.close()

        if len(rows) < 5:
            return UmapProjectionResponse(points=[], error="too few tracks with embeddings")

        # Парсим vector из текста '[0.1,0.2,...]'
        import json
        embs = []
        meta = []
        for r in rows:
            vec_str = r["feature_vector"]
            try:
                vec = np.array(json.loads(vec_str), dtype=np.float32)
                if vec.shape[0] != 2048:
                    continue
                embs.append(vec)
                meta.append({
                    "id": r["id"],
                    "artist": r["artist"],
                    "title": r["title"],
                    "cover_url": r["cover_url"],
                })
            except (json.JSONDecodeError, ValueError):
                continue

        if len(embs) < 5:
            return UmapProjectionResponse(points=[], error="parse failed")

        arr = np.stack(embs)
        log.info("umap: fit on %d × %d", arr.shape[0], arr.shape[1])
        reducer = umap.UMAP(n_components=2, n_neighbors=15, min_dist=0.1, metric="cosine", random_state=42)
        coords = reducer.fit_transform(arr)

        # Нормализуем в [0..1]
        x_min, x_max = float(coords[:, 0].min()), float(coords[:, 0].max())
        y_min, y_max = float(coords[:, 1].min()), float(coords[:, 1].max())
        x_range = max(x_max - x_min, 1e-6)
        y_range = max(y_max - y_min, 1e-6)

        points = []
        for i, m in enumerate(meta):
            points.append(UmapPoint(
                id=m["id"],
                artist=m["artist"],
                title=m["title"],
                cover_url=m["cover_url"],
                x=float((coords[i, 0] - x_min) / x_range),
                y=float((coords[i, 1] - y_min) / y_range),
            ))

        _UMAP_CACHE["data"] = points
        _UMAP_CACHE["ts"] = time.time()
        return UmapProjectionResponse(points=points)
    except Exception as e:
        log.warning("umap-projection failed: %s", e)
        return UmapProjectionResponse(points=[], error=str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("src.main:app", host=config.sidecar_host, port=config.sidecar_port)
