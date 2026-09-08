from __future__ import annotations
import asyncio
import logging

from fastapi import FastAPI
from pydantic import BaseModel

from .chart_routes import router as chart_router
from .config import config

logging.basicConfig(
    level=config.log_level,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("downloader")

app = FastAPI(title="SoundFlow Downloader", version="3.0.0")
# Чарт-эндпоинты вынесены в chart_routes.py (парсеры для «автоподбора по вкусу»).
app.include_router(chart_router)

# Лимит одновременных исходящих запросов (поиск через провайдеров). 3 —
# баланс между скоростью и нагрузкой на домашний роутер.
_OUTBOUND_LIMIT = asyncio.Semaphore(3)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "soundflow-downloader", "version": "3.0.0"}


# ─────────────────── режим 1: «Найти трек» (авто-цепочка) ───────────────────


class FindAudioRequest(BaseModel):
    artist: str
    title: str
    # Skip-list провайдеров (имена как в audio_chain). По умолчанию пусто.
    skip_providers: list[str] = []
    # Source URLs которые уже отклонены для этого трека (см. rejected_track_files
    # в БД). Провайдеры пропустят кандидата с таким source_url.
    rejected_source_urls: list[str] = []
    # Эталонная длительность (сек). Задана — chain отбрасывает версии не той
    # длины (ремикс/обрезка). None — chain сам спросит Яндекс по artist+title.
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
    # Доп. mp3 из того же альбома (только для торрент-альбомов).
    extra_tracks: list[ExtraTrack] = []


@app.post("/find-audio", response_model=FindAudioResponse)
async def find_audio(req: FindAudioRequest) -> FindAudioResponse:
    """Поиск+скачивание одного трека через авто-цепочку: Яндекс → musify →
    mp3party. Берёт лучшую версию (Яндекс = точная студийная 320)."""
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
    # На brain path translation — no-op (canonical == local).
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


# ─────────────────── режим 2: «Торренты — обзор» (руками) ───────────────────


class TorrentSearchRequest(BaseModel):
    artist: str
    # Пусто — все релизы артиста; задан — фильтр по названию альбома.
    album: str | None = None
    trackers: list[str] = []  # пусто = все (nnmclub, rutor, tapochek, rustorka)


class TorrentCandidate(BaseModel):
    tracker: str
    forum_url: str
    dl_ref: str = ""      # ссылка/id для скачивания .torrent (обратно в /download)
    magnet: str | None = None
    title: str            # как на трекере
    album: str | None = None
    year: int | None = None
    fmt: str | None = None       # mp3 | flac | …
    bitrate_kbps: int | None = None
    size_bytes: int | None = None
    seeders: int | None = None
    leechers: int | None = None


class TorrentSearchResponse(BaseModel):
    candidates: list[TorrentCandidate] = []
    errors: list[str] = []


@app.post("/torrent/search", response_model=TorrentSearchResponse)
async def torrent_search(req: TorrentSearchRequest) -> TorrentSearchResponse:
    """Опрос торрент-трекеров по артисту — вернуть список релизов БЕЗ
    скачивания. Alex смотрит и выбирает в окне."""
    log.info("torrent/search: artist=%r album=%r trackers=%r", req.artist, req.album, req.trackers)
    from .providers.torrent_browse import search_all
    async with _OUTBOUND_LIMIT:
        cands, errs = await search_all(req.artist, req.album, set(req.trackers))
    return TorrentSearchResponse(
        candidates=[TorrentCandidate(**c) for c in cands], errors=errs,
    )


class TorrentDownloadRequest(BaseModel):
    tracker: str
    forum_url: str
    dl_ref: str = ""     # из TorrentCandidate.dl_ref
    # Опционально: если задан — из альбома вытащить именно этот трек как
    # «целевой». Пусто — весь альбом равнозначно.
    want_title: str | None = None


class TorrentDownloadResponse(BaseModel):
    found: bool
    album_dir: str | None = None
    tracks: list[ExtraTrack] = []
    error: str | None = None


@app.post("/torrent/download", response_model=TorrentDownloadResponse)
async def torrent_download(req: TorrentDownloadRequest) -> TorrentDownloadResponse:
    """Скачать выбранный на трекере альбом через qBittorrent, вернуть список
    mp3 (canonical пути) для добавления в каталог."""
    log.info("torrent/download: tracker=%s url=%s", req.tracker, req.forum_url)
    from .providers.torrent_browse import download_pick
    result = await download_pick(req.tracker, req.forum_url, req.dl_ref, req.want_title)
    if result is None:
        return TorrentDownloadResponse(found=False, error="не удалось скачать")
    return TorrentDownloadResponse(
        found=True,
        album_dir=result["album_dir"],
        tracks=[
            ExtraTrack(**{**t, "file_path": config.to_canonical(t["file_path"])})
            for t in result["tracks"]
        ],
    )


# ─────────────────── вспомогательное ───────────────────


class Id3InfoRequest(BaseModel):
    file_path: str


class Id3InfoResponse(BaseModel):
    title: str | None = None
    artist: str | None = None


@app.post("/id3-info", response_model=Id3InfoResponse)
async def id3_info(req: Id3InfoRequest) -> Id3InfoResponse:
    """Прочитать теги (артист+название) из локального файла — API так ловит
    расхождение канонического имени трека с реальным ID3 (ремиксы и т.п.)."""
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
    """Поиск артиста в Яндекс Музыке → имя + фото + топ-треки."""
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
    """Обложка трека в Яндекс Музыке по артист+название."""
    from .providers.yandex import find_track_cover
    url = await find_track_cover(req.artist, req.title)
    return YandexCoverResponse(found=bool(url), cover_url=url)


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
    """Поиск + скачивание трека с musify.club."""
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
    """Поиск трека на musify.club (без скачивания)."""
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


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("src.main:app", host=config.sidecar_host, port=config.sidecar_port)
