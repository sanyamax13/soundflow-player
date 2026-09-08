"""Режим 2 «Торренты — обзор» — поиск по артисту на трекерах со списком
релизов (без скачивания), потом скачивание выбранного через qBittorrent.

СТАТУС: каркас. Провайдеры nnmclub_album / rutor_album / tapochek_album
уже есть (их `_do_search` даёт список), rustorka_album — написать.
Здесь: собрать их выдачу в общий формат + расщепить download-половину.
Пока `/torrent/*` отвечает «в разработке», чтобы режим 1 («Найти трек»)
можно было выпустить раньше.
"""
from __future__ import annotations

import logging

log = logging.getLogger(__name__)

_TRACKERS = ("nnmclub", "rutor", "tapochek", "rustorka")


async def search_all(
    artist: str, album: str | None, trackers: set[str],
) -> tuple[list[dict], list[str]]:
    """Опросить трекеры по артисту, вернуть (кандидаты, ошибки).

    Кандидат: {tracker, forum_url, magnet, title, album, year, fmt,
               bitrate_kbps, size_bytes, seeders, leechers}.
    """
    log.info("torrent_browse.search_all: artist=%r album=%r trackers=%r",
             artist, album, trackers or set(_TRACKERS))
    return [], ["Режим «Торренты — обзор» ещё в разработке"]


async def download_pick(
    tracker: str, forum_url: str, magnet: str | None, want_title: str | None,
) -> dict | None:
    """Скачать выбранный на трекере релиз через qBittorrent. Вернуть
    {album_dir, tracks:[{file_path, artist, title, album, duration_sec,
    bitrate_kbps, size_bytes}]} или None."""
    log.info("torrent_browse.download_pick: %s %s", tracker, forum_url)
    return None
