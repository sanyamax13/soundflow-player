"""Координатор источников аудио — параллельный запуск (rev. 11.05.2026).

Стратегия. Качественные источники (rutor, rutracker, tapochek, mp3party, Soulseek)
пробуются последовательно — они дают 320 kbps mp3 или FLAC, но медленные:
торрент может качаться 1-10 минут, slskd-search 15-30 секунд. Быстрые fallback'и
(YouTube Music, SoundCloud) дают 128 kbps Opus/mp3 за 5-30 секунд.

Раньше fallback запускался ПОСЛЕ всей торрент-цепочки. Если у артиста нет
ничего на торрентах (Lady Gaga / Sia / Billie Eilish), то цепочка
прогоняла все 4 торрент-провайдера, ловила timeout'ы, тратила 10-30 минут
на трек и в конце звала YT Music — который ответил бы за 5 секунд если бы
запустился сразу.

Теперь YT Music + SoundCloud стартуют в `asyncio.create_task` СРАЗУ при
входе в функцию, параллельно с торрент-цепочкой. Если торренты дали 320k
— берём их (high-quality), fast tasks отменяем. Если торренты не дали
ничего — fast уже скорее всего готовы, забираем их результат.

Профит: для артистов вне торрентов экономим 90%+ времени; для артистов
с торрентами почти ничего не теряем (только лишние fast-запросы которые
отменяем).
"""
from __future__ import annotations

import asyncio
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ..config import config
from ._validators import duration_off
from ..parsers.yandex_chart import yandex_track_duration
from . import soundcloud_download as sc
from . import rutor_album as rtr
# rutracker отключён из chain 07.06 по просьбе (постоянный Cloudflare 521-шторм,
# ненадёжен; NNM-Club + rutor его заменяют). Модуль rutracker_album всё равно
# импортируют nnmclub_album/rutor_album ради общих helpers, поэтому файл не трогаем.
from . import nnmclub_album as nnm
from . import tapochek_album as tap
from . import youtube_music_download as ytm
from . import soulseek_download as ss
from . import musify_download as mus
from . import yandex as ym

# mp3party_download импортирован явно, но НЕ подключён в chain (11.05.2026):
# в РФ 2026 dl2.mp3party.net стабильно отдаёт 29-байтовые «failed to get file
# info» заглушки вместо mp3. Каждый запрос тратил 5-10 секунд на 19 попыток
# впустую. Файл оставлен — если ситуация починится, верним обратно.

log = logging.getLogger(__name__)


@dataclass
class AudioChainResult:
    file_path: str
    bitrate_kbps: int | None
    duration_sec: int | None
    size_bytes: int
    source: str
    provider_user: str
    provider_url: str
    # Дополнительные mp3 из того же альбома (только для rutor_album / rutracker_album / tapochek_album).
    extra_tracks: list[dict[str, Any]] = field(default_factory=list)


def _album_extras(all_tracks: list, target_file_path: str) -> list[dict[str, Any]]:
    extra: list[dict[str, Any]] = []
    for t in all_tracks:
        if t.file_path == target_file_path:
            continue
        extra.append(
            {
                "file_path": t.file_path,
                "artist": t.artist,
                "title": t.title,
                "album": t.album,
                "duration_sec": t.duration_sec,
                "bitrate_kbps": t.bitrate_kbps,
                "size_bytes": t.size_bytes,
            }
        )
    return extra


def _torrent_to_chain(album_result: Any, source: str, provider_user: str) -> AudioChainResult:
    """Build AudioChainResult из RutrackerDownloadResult / RutorDownloadResult /
    TapochekDownloadResult — у всех одинаковая структура (target_meta + all_tracks + forum_url)."""
    meta = album_result.target_meta
    return AudioChainResult(
        file_path=album_result.target_file_path,
        bitrate_kbps=meta.bitrate_kbps,
        duration_sec=meta.duration_sec,
        size_bytes=meta.size_bytes,
        source=source,
        provider_user=provider_user,
        provider_url=album_result.forum_url,
        extra_tracks=_album_extras(album_result.all_tracks, album_result.target_file_path),
    )


def _cancel_pending(tasks: dict[str, asyncio.Task]) -> None:
    """Отменяет fast-задачи которые ещё не завершились. Cancel у уже-done
    задач безопасен (no-op)."""
    for t in tasks.values():
        if not t.done():
            t.cancel()


def _delete_losing_file(
    candidate_path: str | None,
    winner_path: str | None,
    reason: str,
    *,
    cache_dir: Path | None = None,
    albums_dir: Path | None = None,
) -> bool:
    """Безопасное удаление файла проигравшего fast-task'а.

    Возвращает True только если файл реально был на диске и удалён.
    Никогда не бросает.

    Страховки:
      - пустой candidate_path → False
      - candidate == winner → False (страховка от самоудаления выбранного)
      - вне cache_dir → False (защита от music/album folders,
        slskd-downloads и любых других путей)
      - внутри albums_dir → False (доп. защита от album seeding)
      - !exists → False (уже подметено / yt-dlp не дописал)

    `cache_dir` и `albums_dir` опциональны — по умолчанию берём из
    `config.track_cache_dir` и `config.albums_dir`. Параметры существуют
    для unit-тестов (config — frozen dataclass, monkeypatch на него не
    работает).

    .part-файлы от прерванных yt-dlp/SoundCloud task.cancel() здесь
    НЕ обрабатываются — это отдельный долг.
    """
    if not candidate_path:
        return False
    if winner_path and candidate_path == winner_path:
        return False
    try:
        cand = Path(candidate_path).resolve()
    except OSError:
        return False
    cd = (cache_dir if cache_dir is not None else config.track_cache_dir).resolve()
    ad = (albums_dir if albums_dir is not None else config.albums_dir).resolve()
    try:
        cand.relative_to(cd)
    except ValueError:
        return False
    # Доп.: если cache_dir и albums_dir вложены/пересекаются, ещё раз
    # проверяем что мы не в albums.
    try:
        cand.relative_to(ad)
        return False
    except ValueError:
        pass
    if not cand.exists():
        return False
    try:
        cand.unlink()
        log.info("audio_chain: deleted losing candidate (%s): %s", reason, candidate_path)
        return True
    except OSError as exc:
        log.warning(
            "audio_chain: failed to delete losing candidate %s: %s",
            candidate_path,
            exc,
        )
        return False


def _result_file_path(result: Any) -> str | None:
    """Извлекает file_path из YT Music / SoundCloud download result."""
    if result is None:
        return None
    fp = getattr(result, "file_path", None)
    return fp if isinstance(fp, str) and fp else None


def _cancel_and_cleanup_fast(
    fast_tasks: dict[str, asyncio.Task],
    winner_path: str | None,
    won_by: str,
) -> None:
    """Отменяет pending fast-задачи и удаляет файлы тех, кто УЖЕ
    скачал кандидата до того как мы выбрали winner.

    Для каждого task в fast_tasks:
      - если pending (not done) → cancel(); .part файл может остаться,
        это отдельный долг;
      - если done с success result → удалить result.file_path через
        _delete_losing_file (он не тронет winner_path и пути вне cache);
      - если done с None / CancelledError / exception → пропускаем.

    `won_by` идёт только в лог как reason='lost_to_<won_by>'.
    """
    for name, task in fast_tasks.items():
        if not task.done():
            task.cancel()
            continue
        try:
            result = task.result()
        except asyncio.CancelledError:
            continue
        except BaseException as exc:  # noqa: BLE001 — лог и продолжаем
            log.warning("audio_chain: fast %s упал: %s", name, exc)
            continue
        candidate_path = _result_file_path(result)
        if candidate_path:
            _delete_losing_file(candidate_path, winner_path, f"lost_to_{won_by}")


async def _await_fast_results(
    fast_tasks: dict[str, asyncio.Task],
    artist: str,
) -> AudioChainResult | None:
    """Ждёт fast-задачи и возвращает первый success. Если все None / exception
    — возвращает None. Порядок предпочтения = порядок в dict (YT Music сначала)."""
    for name, task in fast_tasks.items():
        try:
            result = await task
        except asyncio.CancelledError:
            continue
        except Exception as exc:
            log.warning("audio_chain: fast %s упал: %s", name, exc)
            continue
        if result is None:
            continue

        chain_result: AudioChainResult | None = None
        if name == "youtube_music":
            log.info("audio_chain: %s — YouTube Music успех (background, uploader=%s)", artist, result.uploader)
            chain_result = AudioChainResult(
                file_path=result.file_path,
                bitrate_kbps=result.bitrate_kbps,
                duration_sec=result.duration_sec,
                size_bytes=result.size_bytes,
                source=result.source,
                provider_user=result.uploader,
                provider_url=result.youtube_url,
            )
        elif name == "soundcloud":
            log.info("audio_chain: %s — SoundCloud успех (background)", artist)
            chain_result = AudioChainResult(
                file_path=result.file_path,
                bitrate_kbps=result.bitrate_kbps,
                duration_sec=result.duration_sec,
                size_bytes=result.size_bytes,
                source=result.source,
                provider_user=result.soundcloud_user,
                provider_url=result.soundcloud_url,
            )

        # Cleanup losing fast-задач: cancel pending + удалить файлы тех,
        # кто УЖЕ завершился до того как мы выбрали winner'а. Winner
        # защищён через winner_path сравнение внутри helper'а.
        winner_path = chain_result.file_path if chain_result is not None else None
        _cancel_and_cleanup_fast(fast_tasks, winner_path, name)
        return chain_result
    return None


async def _safe_provider(coro: Any, name: str) -> Any:
    """Изоляция источника в цепочке. Сетевой сбой ОДНОГО провайдера (например
    musify, рвущий HTTP/2: curl 92 PROTOCOL_ERROR) раньше пробрасывался наружу
    и ронял весь /find-audio в 500 — при том что соседние источники могли найти
    трек. Теперь исключение провайдера = «этот источник ничего не дал», цепочка
    идёт дальше. CancelledError пробрасываем — отмена задач должна работать."""
    try:
        return await coro
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        log.warning("audio_chain: провайдер %s упал (%s), пропускаю", name, exc)
        return None


async def find_audio_chain(
    artist: str,
    title: str,
    *,
    skip_providers: set[str] | None = None,
    rejected_source_urls: set[str] | None = None,
    expected_duration_sec: int | None = None,
) -> AudioChainResult | None:
    skip = skip_providers or set()
    rejected = rejected_source_urls or set()

    # Эталон длины из Яндекса — чтобы из любого источника бралась именно та
    # версия (а ремикс/обрезка/чужая запись под тем же именем отбрасывалась).
    # Если не передан явно — ищем сами (best-effort; None → фильтр выключен).
    if expected_duration_sec is None:
        expected_duration_sec = await _safe_provider(
            asyncio.to_thread(yandex_track_duration, artist, title), "yandex-duration")
        if expected_duration_sec:
            log.info("audio_chain: %s — %s эталон длины %ss (Яндекс)", artist, title, expected_duration_sec)

    # === Параллельный старт fast-задач ===
    # YT Music + SoundCloud работают в фоне пока мы пробуем торренты.
    # asyncio.create_task сразу планирует выполнение в loop'е.
    fast_tasks: dict[str, asyncio.Task] = {}
    # YouTube Music ОТКЛЮЧЁН по умолчанию (Алекс 07.06.2026: «ютуб даёт клипы»).
    # YT нередко отдаёт видео/клип-версию вместо студийного трека, и фильтр длины
    # её не всегда ловит. Источник свежей РФ-попсы теперь SoundCloud (impersonate).
    # Вернуть можно env ENABLE_YOUTUBE_MUSIC=1, не трогая код.
    if "youtube_music" not in skip and os.environ.get("ENABLE_YOUTUBE_MUSIC") == "1":
        fast_tasks["youtube_music"] = asyncio.create_task(
            ytm.find_and_download(artist, title, rejected_source_urls=rejected,
                                  expected_duration_sec=expected_duration_sec)
        )
    if "soundcloud" not in skip:
        fast_tasks["soundcloud"] = asyncio.create_task(
            sc.find_and_download(artist, title, rejected_source_urls=rejected,
                                 expected_duration_sec=expected_duration_sec)
        )
    try:
        # === Yandex Music — ПЕРВЫЙ источник (11.06.2026, Алекс «по максимуму
        # использовать Яндекс»): личный Плюс, почти весь русский каталог в 320.
        # Самый надёжный по качеству. Нет токена → провайдер вернёт None
        # (выключен), цепочка идёт дальше как раньше.
        if "yandex" not in skip:
            ym_res = await _safe_provider(ym.download_track(
                artist, title, config.track_cache_dir,
                expected_duration_sec=expected_duration_sec), "yandex")
            if ym_res is not None:
                ym_path, ym_match = ym_res
                log.info("audio_chain: %s — Yandex успех (%skbps)", artist, ym_match.bitrate_kbps)
                _cancel_and_cleanup_fast(fast_tasks, ym_path, "yandex")
                return AudioChainResult(
                    file_path=ym_path,
                    bitrate_kbps=ym_match.bitrate_kbps,
                    duration_sec=ym_match.duration_sec,
                    size_bytes=os.path.getsize(ym_path),
                    source="yandex",
                    provider_user="yandex",
                    provider_url=f"yandexmusic://{ym_match.track_id}",
                )

        # === musify — ОСНОВНОЙ источник (Алекс 08.06): свободный 320 mp3.
        # Торренты для свежих синглов почти не отдают, а musify отдаёт сразу.
        # Спрашиваем musify ПЕРВЫМ; нашёл — берём, не тратя время на торренты.
        # Не нашёл — падаем в торрент-цепочку (она ещё и грабит альбомы целиком).
        if "musify" not in skip:
            mus_result = await _safe_provider(mus.find_and_download(
                artist, title, rejected_source_urls=rejected,
                expected_duration_sec=expected_duration_sec), "musify")
            if mus_result is not None:
                log.info("audio_chain: %s — musify успех (основной, %skbps)",
                         artist, mus_result.bitrate_kbps)
                _cancel_and_cleanup_fast(fast_tasks, mus_result.file_path, "musify")
                return AudioChainResult(
                    file_path=mus_result.file_path,
                    bitrate_kbps=mus_result.bitrate_kbps,
                    duration_sec=mus_result.duration_sec,
                    size_bytes=mus_result.size_bytes,
                    source="musify",
                    provider_user="musify",
                    provider_url=mus_result.source_url,
                )

        # === High-quality torrent chain (sequential) ===
        # 0. nnmclub — ОСНОВНОЙ источник (cookie-вход, mp3, большой каталог)
        if "nnmclub" not in skip:
            nnm_result = await _safe_provider(
                nnm.find_and_download(artist, title, rejected_source_urls=rejected), "nnmclub")
            if nnm_result is not None:
                chain = _torrent_to_chain(nnm_result, "nnmclub_album", "nnmclub")
                if duration_off(chain.duration_sec, expected_duration_sec):
                    log.info("audio_chain: nnmclub wrong duration (%ss vs эталон %ss), пропускаю",
                             chain.duration_sec, expected_duration_sec)
                else:
                    log.info(
                        "audio_chain: %s — nnmclub_album успех (%d mp3 в %s)",
                        artist, len(nnm_result.all_tracks), nnm_result.album_dir,
                    )
                    _cancel_and_cleanup_fast(fast_tasks, nnm_result.target_file_path, "nnmclub")
                    return chain

        # 1. rutor.info — открытый трекер без логина
        if "rutor" not in skip:
            rtr_result = await _safe_provider(
                rtr.find_and_download(artist, title, rejected_source_urls=rejected), "rutor")
            if rtr_result is not None:
                chain = _torrent_to_chain(rtr_result, "rutor_album", "rutor")
                if duration_off(chain.duration_sec, expected_duration_sec):
                    log.info("audio_chain: rutor wrong duration (%ss vs эталон %ss), пропускаю",
                             chain.duration_sec, expected_duration_sec)
                else:
                    log.info(
                        "audio_chain: %s — rutor_album успех (%d mp3 в %s)",
                        artist, len(rtr_result.all_tracks), rtr_result.album_dir,
                    )
                    _cancel_and_cleanup_fast(fast_tasks, rtr_result.target_file_path, "rutor")
                    return chain

        # 2. rutracker — ОТКЛЮЧЁН 07.06 по просьбе (постоянный Cloudflare 521-шторм,
        # ненадёжен; NNM-Club + rutor его заменяют). Чтобы вернуть — раскомментировать
        # этот блок и импорт `rt` сверху.

        # 3. tapochek — phpBB, русская музыка
        if "tapochek" not in skip:
            tap_result = await _safe_provider(
                tap.find_and_download(artist, title, rejected_source_urls=rejected), "tapochek")
            if tap_result is not None:
                chain = _torrent_to_chain(tap_result, "tapochek_album", "tapochek")
                if duration_off(chain.duration_sec, expected_duration_sec):
                    log.info("audio_chain: tapochek wrong duration (%ss vs эталон %ss), пропускаю",
                             chain.duration_sec, expected_duration_sec)
                else:
                    log.info(
                        "audio_chain: %s — tapochek_album успех (%d mp3 в %s)",
                        artist, len(tap_result.all_tracks), tap_result.album_dir,
                    )
                    _cancel_and_cleanup_fast(fast_tasks, tap_result.target_file_path, "tapochek")
                    return chain

        # 4. (отключено) mp3party.net — в РФ 2026 всегда 29-байтовые stubs.
        # См. комментарий выше impортов.

        # 5. Soulseek — P2P, 256+ kbps
        if "soulseek" not in skip:
            ss_result = await _safe_provider(ss.find_and_download(
                artist, title, min_bitrate_kbps=256, max_candidates=3,
                rejected_source_urls=rejected,
            ), "soulseek")
            if ss_result is not None:
                if duration_off(ss_result.duration_sec, expected_duration_sec):
                    log.info("audio_chain: soulseek wrong duration (%ss vs эталон %ss), пропускаю",
                             ss_result.duration_sec, expected_duration_sec)
                else:
                    log.info("audio_chain: %s — Soulseek успех (peer=%s)", artist, ss_result.soulseek_user)
                    _cancel_and_cleanup_fast(fast_tasks, ss_result.file_path, "soulseek")
                    return AudioChainResult(
                        file_path=ss_result.file_path,
                        bitrate_kbps=ss_result.bitrate_kbps,
                        duration_sec=ss_result.duration_sec,
                        size_bytes=ss_result.size_bytes,
                        source="soulseek",
                        provider_user=ss_result.soulseek_user,
                        provider_url=f"slsk://{ss_result.soulseek_user}/{ss_result.soulseek_filename}",
                    )

        # === High-quality не дала — забираем результат от fast-задач ===
        # Они скорее всего уже завершились пока торренты пробовали.
        fast_result = await _await_fast_results(fast_tasks, artist)
        if fast_result is not None:
            return fast_result

        log.info("audio_chain: %s — %s не найден ни одним источником", artist, title)
        return None
    finally:
        # Страховка: гарантированно отменяем оставшиеся fast-задачи
        # (если был раний return или exception мимо нашей логики).
        _cancel_pending(fast_tasks)
